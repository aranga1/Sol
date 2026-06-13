"""CalendarExtractor — reads macOS iCloud Calendar events via PyObjC EventKit.

Implements the SourceExtractor protocol. Polls EKEventStore for events in a
rolling 90-day window (past and future). Returns an IndexDiff describing new,
modified, and deleted events relative to the IndexManifest.
"""
from __future__ import annotations

import logging
import threading
from datetime import datetime
from typing import TYPE_CHECKING

from llama_index.core.schema import TextNode

from solidrag.extractors.base import IndexDiff

if TYPE_CHECKING:
    from solidrag.index.manifest import IndexManifest

logger = logging.getLogger(__name__)

_90_DAYS_S: float = 90 * 24 * 3600.0


def _format_event(event) -> str:
    """Format an EKEvent-like object into a dense, embeddable text block."""
    title = event.title() or "Untitled"

    start_ts = event.startDate().timeIntervalSince1970()
    end_ts = event.endDate().timeIntervalSince1970()
    start_dt = datetime.fromtimestamp(start_ts)
    end_dt = datetime.fromtimestamp(end_ts)

    date_str = start_dt.strftime("%A %d %B %Y")
    time_str = (
        f"{start_dt.strftime('%I:%M%p').lstrip('0')} – "
        f"{end_dt.strftime('%I:%M%p').lstrip('0')}"
    )

    parts = [f"Event: {title}", f"Date: {date_str}, {time_str}"]

    if location := event.location():
        parts.append(f"Location: {location}")

    if attendees := event.attendees():
        names = [a.name() for a in attendees if a.name()]
        if names:
            parts.append(f"Attendees: {', '.join(names)}")

    if notes := event.notes():
        stripped = notes.strip()
        if stripped:
            parts.append(f"Notes: {stripped}")

    return "\n".join(parts)


class CalendarExtractor:
    """SourceExtractor for macOS Calendar via EventKit (PyObjC).

    Authorization is requested once at init time. If the user denies access
    or PyObjC is unavailable, sync() returns an empty IndexDiff and logs a
    warning — it never raises.
    """

    source_id: str = "calendar"

    def __init__(self) -> None:
        self._store = None
        self._authorized = False
        self._init_store()

    def _init_store(self) -> None:
        try:
            import EventKit  # type: ignore[import]

            store = EventKit.EKEventStore.alloc().init()
            done = threading.Event()
            result: list[bool] = [False]

            def _callback(granted, _error):
                result[0] = bool(granted)
                done.set()

            store.requestAccessToEntityType_completion_(
                EventKit.EKEntityTypeEvent, _callback
            )
            done.wait(timeout=30)

            if result[0]:
                self._store = store
                self._authorized = True
            else:
                logger.warning("CalendarExtractor: calendar access denied by user")
        except Exception as exc:
            logger.warning("CalendarExtractor: could not initialise EventKit: %s", exc)

    def _fetch_events(self) -> list:
        import EventKit  # type: ignore[import]
        from Foundation import NSDate  # type: ignore[import]

        if not self._authorized or self._store is None:
            return []

        self._store.refreshSourcesIfNecessary()
        start = NSDate.dateWithTimeIntervalSinceNow_(-_90_DAYS_S)
        end = NSDate.dateWithTimeIntervalSinceNow_(_90_DAYS_S)
        predicate = self._store.predicateForEventsWithStartDate_endDate_calendars_(
            start, end, None
        )
        events = self._store.eventsMatchingPredicate_(predicate)
        return list(events) if events else []

    def sync(self, manifest: IndexManifest) -> IndexDiff:
        """Diff EventKit against the manifest and return an IndexDiff."""
        diff = IndexDiff()

        try:
            events = self._fetch_events()
        except Exception as exc:
            logger.warning("CalendarExtractor: fetch failed: %s", exc)
            return diff

        existing = {
            key: manifest.get_source(self.source_id, key)
            for key in manifest.all_source_keys(self.source_id)
        }
        current_ids: set[str] = set()

        for event in events:
            event_id = event.eventIdentifier()
            if not event_id:
                continue
            current_ids.add(event_id)

            lm_date = event.lastModifiedDate()
            last_modified = lm_date.timeIntervalSince1970() if lm_date else 0.0

            prev = existing.get(event_id)
            if prev is None:
                node = TextNode(
                    text=_format_event(event),
                    metadata={"source": "calendar", "event_id": event_id},
                )
                node.excluded_llm_metadata_keys = ["source", "event_id"]
                diff.to_add.append(node)
                manifest.update_source(
                    self.source_id, event_id, last_modified, [node.node_id]
                )
            elif prev.mtime != last_modified:
                node = TextNode(
                    text=_format_event(event),
                    metadata={"source": "calendar", "event_id": event_id},
                )
                node.excluded_llm_metadata_keys = ["source", "event_id"]
                diff.to_update.append((list(prev.node_ids), [node]))
                manifest.update_source(
                    self.source_id, event_id, last_modified, [node.node_id]
                )

        for event_id, entry in existing.items():
            if event_id not in current_ids:
                if entry:
                    diff.to_delete.extend(entry.node_ids)
                manifest.remove_source(self.source_id, event_id)

        return diff
