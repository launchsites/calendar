"""A range-based iCloud Calendar store with conditional writes."""

from dataclasses import dataclass
from datetime import date, datetime, time, timedelta, timezone
import re
from urllib.parse import urljoin, urlsplit
from uuid import uuid4

from defusedxml import ElementTree as XML
import icalendar
import recurring_ical_events
import requests


DAV = "{DAV:}"
CAL = "{urn:ietf:params:xml:ns:caldav}"
APPLE = "{http://apple.com/ns/ical/}"
ROOT = "https://caldav.icloud.com/"
NS = 'xmlns:d="DAV:" xmlns:c="urn:ietf:params:xml:ns:caldav" xmlns:a="http://apple.com/ns/ical/"'


class CalendarError(Exception):
    pass


@dataclass(frozen=True)
class Calendar:
    url: str
    title: str
    color: str
    writable: bool


@dataclass(frozen=True)
class Event:
    key: str
    calendar: Calendar
    href: str
    etag: str
    title: str
    start: datetime
    end: datetime
    all_day: bool
    notes: str
    raw: bytes
    editable: bool


@dataclass(frozen=True)
class Draft:
    title: str
    start: date | datetime
    end: date | datetime
    notes: str
    weekly: bool = False


def cloud_url(base, href):
    url = urljoin(base, href)
    try:
        parts = urlsplit(url)
        permitted = re.fullmatch(r"(?:p[0-9]+-)?caldav\.icloud\.com", parts.hostname or "")
        if (parts.scheme == "https" and permitted and parts.port in (None, 443)
                and parts.username is None and parts.password is None and not parts.fragment):
            return url
    except ValueError:
        pass
    raise CalendarError("iCloud returned an unexpected server address.")


def properties(xml):
    for response in xml.findall(DAV + "response"):
        href = response.findtext(DAV + "href")
        values = {}
        for propstat in response.findall(DAV + "propstat"):
            status = propstat.findtext(DAV + "status", "")
            prop = propstat.find(DAV + "prop")
            if len(status.split()) >= 2 and status.split()[1] == "200" and prop is not None:
                values.update({node.tag: node for node in prop})
        if href:
            yield href, values


def local_time(value, zone):
    if isinstance(value, datetime):
        return value.astimezone(zone) if value.tzinfo else value.replace(tzinfo=zone)
    return datetime.combine(value, time.min, zone)


def occurrences(calendar, href, etag, raw, start, end, zone):
    resource = icalendar.Calendar.from_ical(raw)
    original = resource.walk("VEVENT")
    recurring = len(original) != 1 or any(
        name in component for component in original
        for name in ("RRULE", "RDATE", "EXDATE", "RECURRENCE-ID", "EXRULE")
    )
    components = (recurring_ical_events.of(resource).between(start, end)
                  if recurring else original)
    for component in components:
        if "DTSTART" not in component or str(component.get("STATUS", "")) == "CANCELLED":
            continue
        raw_start = component.decoded("DTSTART")
        all_day = not isinstance(raw_start, datetime)
        begins = local_time(raw_start, zone)
        if "DTEND" in component:
            ends = local_time(component.decoded("DTEND"), zone)
        else:
            duration = component.decoded("DURATION") if "DURATION" in component else (
                timedelta(days=1) if all_day else timedelta()
            )
            ends = begins + duration
        if begins.timestamp() >= end.timestamp() or (
            ends.timestamp() <= start.timestamp() and begins.timestamp() < start.timestamp()
        ):
            continue
        notes = str(component.get("DESCRIPTION", ""))
        editable = calendar.writable and bool(etag) and not recurring and not any(
            name in component for name in ("ATTENDEE", "ORGANIZER")
        ) and "[Link ID:" not in notes
        key = href + "#" + str(component.get("UID", "")) + "@" + begins.isoformat()
        yield Event(key, calendar, href, etag, str(component.get("SUMMARY", "")) or "Untitled event",
                    begins, ends, all_day, notes, raw, editable)


class ICloudStore:
    def __init__(self, username, password):
        self.credentials = (username, password)

    def request(self, method, url, body=None, headers=None):
        target = cloud_url(ROOT, url)
        for _ in range(6):
            try:
                response = requests.request(
                    method, target, auth=self.credentials, data=body, headers=headers,
                    allow_redirects=False, timeout=(5, 12),
                )
            except requests.RequestException:
                raise CalendarError("Couldn’t reach iCloud. Check your connection and try again.") from None
            if response.status_code in (301, 302, 307, 308) and response.headers.get("Location"):
                target = cloud_url(target, response.headers["Location"])
                continue
            if response.status_code == 401:
                raise CalendarError("iCloud didn’t accept the sign-in. Check your email and app-specific password.")
            if response.status_code == 412:
                raise CalendarError("This event changed on another device. Refresh and reopen it.")
            if response.status_code == 404:
                raise CalendarError("The calendar or event is no longer available.")
            if response.status_code == 403:
                raise CalendarError("iCloud denied access to this calendar or event.")
            if not 200 <= response.status_code < 300:
                raise CalendarError(f"iCloud returned HTTP {response.status_code}.")
            return response
        raise CalendarError("iCloud sent too many redirects.")

    def query(self, method, url, body, depth):
        response = self.request(method, url, body.encode(), {
            "Depth": str(depth), "Content-Type": "application/xml; charset=utf-8",
        })
        try:
            root = XML.fromstring(response.content)
        except (XML.ParseError, ValueError):
            raise CalendarError("iCloud sent an unreadable calendar response.") from None
        if root.tag != DAV + "multistatus":
            raise CalendarError("iCloud sent an unexpected calendar response.")
        return response.url, list(properties(root))

    def discover(self):
        base, rows = self.query("PROPFIND", ROOT, f'<d:propfind {NS}><d:prop>'
                                '<d:current-user-principal/></d:prop></d:propfind>', 0)
        principal = self.find_href(base, rows, DAV + "current-user-principal")
        base, rows = self.query("PROPFIND", principal, f'<d:propfind {NS}><d:prop>'
                                '<c:calendar-home-set/></d:prop></d:propfind>', 0)
        home = self.find_href(base, rows, CAL + "calendar-home-set")
        base, rows = self.query("PROPFIND", home, f'<d:propfind {NS}><d:prop>'
                                '<d:displayname/><d:resourcetype/><a:calendar-color/>'
                                '<c:supported-calendar-component-set/><d:current-user-privilege-set/>'
                                '</d:prop></d:propfind>', 1)
        calendars = {}
        for href, values in rows:
            types = values.get(DAV + "resourcetype")
            if types is None or types.find(CAL + "calendar") is None:
                continue
            supported = values.get(CAL + "supported-calendar-component-set")
            if supported is not None and not any(elem.attrib.get("name") == "VEVENT" for elem in supported):
                continue
            privileges = values.get(DAV + "current-user-privilege-set")
            writable = privileges is None or any(
                privileges.find(".//" + DAV + name) is not None
                for name in ("all", "write", "write-content")
            )
            title = getattr(values.get(DAV + "displayname"), "text", None) or "Untitled calendar"
            color = getattr(values.get(APPLE + "calendar-color"), "text", None) or ""
            url = cloud_url(base, href)
            if not url.endswith("/"):
                url += "/"
            calendars[url] = Calendar(url, title, color[:7] if re.fullmatch(r"#[0-9A-Fa-f]{6}(?:[0-9A-Fa-f]{2})?", color) else "#6197e8", writable)
        return sorted(calendars.values(), key=lambda calendar: calendar.title.casefold())

    @staticmethod
    def find_href(base, rows, key):
        for _, values in rows:
            node = values.get(key)
            href = node.findtext(DAV + "href") if node is not None else None
            if href:
                return cloud_url(base, href)
        raise CalendarError("iCloud didn’t provide a calendar location for this account.")

    def events(self, calendar, start, end, zone):
        begin, finish = (value.astimezone(timezone.utc).strftime("%Y%m%dT%H%M%SZ")
                         for value in (start, end))
        base, rows = self.query("REPORT", calendar.url, f'<c:calendar-query {NS}>'
                                '<d:prop><d:getetag/><c:calendar-data/></d:prop>'
                                '<c:filter><c:comp-filter name="VCALENDAR"><c:comp-filter name="VEVENT">'
                                f'<c:time-range start="{begin}" end="{finish}"/>'
                                '</c:comp-filter></c:comp-filter></c:filter></c:calendar-query>', 1)
        events = {}
        for href, values in rows:
            data = getattr(values.get(CAL + "calendar-data"), "text", None)
            if data:
                tag = getattr(values.get(DAV + "getetag"), "text", "") or ""
                for event in occurrences(calendar, cloud_url(base, href), tag, data.encode(), start, end, zone):
                    events[event.key] = event
        return sorted(events.values(), key=lambda event: event.start)

    def save(self, calendar, draft, original=None):
        if not calendar.writable or (original and (not original.editable or original.calendar != calendar)):
            raise CalendarError("This calendar or event is read-only.")
        start, end = draft.start, draft.end
        ordered = end.timestamp() > start.timestamp() if isinstance(start, datetime) else end > start
        if not draft.title.strip() or not ordered:
            raise CalendarError("Enter a title and an end after the start.")
        if original:
            resource = icalendar.Calendar.from_ical(original.raw)
            component = resource.walk("VEVENT")[0]
            href, precondition = original.href, {"If-Match": original.etag}
            if not component.get("SUMMARY") or str(component["SUMMARY"]) != draft.title:
                replace(component, "SUMMARY", draft.title)
            if str(component.get("DESCRIPTION", "")) != draft.notes:
                replace(component, "DESCRIPTION", draft.notes or None)
            original_start = original.start.date() if original.all_day else original.start
            original_end = original.end.date() if original.all_day else original.end
            unchanged_time = (draft.start, draft.end) == (original_start, original_end)
            if isinstance(draft.start, datetime) and not original.all_day:
                unchanged_time = (draft.start.timestamp(), draft.end.timestamp()) == (
                    original.start.timestamp(), original.end.timestamp()
                )
            if not unchanged_time:
                replace(component, "DTSTART", calendar_date(draft.start))
                replace(component, "DTEND", calendar_date(draft.end))
                component.pop("DURATION", None)
        else:
            resource = icalendar.Calendar()
            resource.add("prodid", "-//Calendar//Linux//EN")
            resource.add("version", "2.0")
            component = icalendar.Event()
            uid = str(uuid4())
            component.add("uid", uid)
            component.add("summary", draft.title)
            component.add("dtstart", calendar_date(draft.start, draft.weekly))
            component.add("dtend", calendar_date(draft.end, draft.weekly))
            if draft.weekly:
                component.add("rrule", {"freq": ["weekly"]})
                if isinstance(draft.start, datetime) and hasattr(draft.start.tzinfo, "key"):
                    tz = icalendar.Timezone.from_tzid(draft.start.tzinfo.key)
                    resource.add_component(tz)
            if draft.notes:
                component.add("description", draft.notes)
            resource.add_component(component)
            href, precondition = urljoin(calendar.url, uid + ".ics"), {"If-None-Match": "*"}
        replace(component, "DTSTAMP", datetime.now(timezone.utc))
        self.request("PUT", href, resource.to_ical(), {
            "Content-Type": "text/calendar; charset=utf-8", **precondition,
        })

    def delete(self, event):
        if not event.editable:
            raise CalendarError("This event is read-only.")
        self.request("DELETE", event.href, headers={"If-Match": event.etag})


def replace(component, name, value):
    component.pop(name, None)
    if value is not None:
        component.add(name, value)


def calendar_date(value, weekly=False):
    if isinstance(value, datetime) and not weekly:
        return value.astimezone(timezone.utc)
    return value
