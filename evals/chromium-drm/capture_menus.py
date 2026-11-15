"""App-filtered ScreenCaptureKit frames, including native menus under blackout."""
import json
from pathlib import Path
import time

import Foundation
import Quartz
import ScreenCaptureKit as SC


def _completed(start, seconds=10):
    result = []
    start(lambda value, error: result.append((value, error)))
    deadline = time.monotonic() + seconds
    while not result and time.monotonic() < deadline:
        Foundation.NSRunLoop.currentRunLoop().runUntilDate_(
            Foundation.NSDate.dateWithTimeIntervalSinceNow_(.02))
    if not result:
        raise RuntimeError('App-filtered ScreenCaptureKit timed out')
    value, error = result[0]
    if error or value is None:
        raise RuntimeError('App-filtered ScreenCaptureKit: ' + str(error))
    return value


def picture_with_menus(pid, path, metadata):
    """Capture only this app on its display, clipped to the verified browser frame.

    Desktop-independent window capture can omit native menu windows on adhd.
    Display-bound application filtering includes its child windows, while
    excluding blackout, other apps, the desktop and the Dock. The caller first
    uses probe_capture.picture to verify the target and raised blackout.
    """
    if not Quartz.CGPreflightScreenCaptureAccess():
        raise RuntimeError('Python has no existing Screen Recording grant; no permission request was made')
    if metadata.get('blackout_pids') and not metadata.get('covering_windows'):
        raise RuntimeError('The raised blackout was not verified')
    content = _completed(lambda done: SC.SCShareableContent.
        getShareableContentExcludingDesktopWindows_onScreenWindowsOnly_completionHandler_(True, False, done))
    application = next((app for app in content.applications() if app.processID() == pid), None)
    if application is None:
        raise RuntimeError('Probe app is absent from ScreenCaptureKit')
    x, y, width, height = metadata['frame']
    center = Quartz.CGPointMake(x + width / 2, y + height / 2)
    display = next((d for d in content.displays() if Quartz.CGRectContainsPoint(d.frame(), center)), None)
    if display is None:
        raise RuntimeError('Probe window has no capture display')
    content_filter = SC.SCContentFilter.alloc().initWithDisplay_includingApplications_exceptingWindows_(
        display, [application], [])
    scale = SC.SCShareableContent.infoForFilter_(content_filter).pointPixelScale()
    configuration = SC.SCStreamConfiguration.alloc().init()
    configuration.setWidth_(round(width * scale))
    configuration.setHeight_(round(height * scale))
    configuration.setShowsCursor_(False)
    configuration.setIncludeChildWindows_(True)
    origin = display.frame().origin
    source_rect = Quartz.CGRectMake(x - origin.x, y - origin.y, width, height)
    configuration.setSourceRect_(source_rect)
    captured = _completed(lambda done: SC.SCScreenshotManager.
        captureImageWithFilter_configuration_completionHandler_(content_filter, configuration, done))
    path = Path(path)
    url = Quartz.CFURLCreateWithFileSystemPath(None, str(path), Quartz.kCFURLPOSIXPathStyle, False)
    destination = Quartz.CGImageDestinationCreateWithURL(url, 'public.png', 1, None)
    if destination is None:
        raise RuntimeError('Cannot create menu screenshot')
    Quartz.CGImageDestinationAddImage(destination, captured, None)
    if not Quartz.CGImageDestinationFinalize(destination):
        raise RuntimeError('Cannot save menu screenshot')
    metadata = dict(metadata, capture='ScreenCaptureKit', content_filter='display-including-probe-app',
                    included_app_pids=[pid], display=int(display.displayID()),
                    display_source_rect=[x - origin.x, y - origin.y, width, height],
                    size=[Quartz.CGImageGetWidth(captured), Quartz.CGImageGetHeight(captured)])
    path.with_suffix('.json').write_text(json.dumps(metadata, indent=2))
    return metadata
