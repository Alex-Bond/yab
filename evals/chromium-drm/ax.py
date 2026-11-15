"""Accessibility helpers for the Opens in acceptance (pyobjc, farm only)."""
import time

import ApplicationServices as AX
import Quartz


def value(element, name):
    err, got = AX.AXUIElementCopyAttributeValue(element, name, None)
    return got if err == 0 else None


def frame(element):
    pos, size = value(element, 'AXPosition'), value(element, 'AXSize')
    if pos is None or size is None:
        return None
    _, p = AX.AXValueGetValue(pos, AX.kAXValueCGPointType, None)
    _, s = AX.AXValueGetValue(size, AX.kAXValueCGSizeType, None)
    return [p.x, p.y, s.width, s.height]


def walk(element, depth=0, limit=40, seen=None):
    """Every element under `element`, depth first."""
    seen = [0] if seen is None else seen
    seen[0] += 1
    if depth > limit or seen[0] > 60000:
        return
    yield element, depth
    for child in value(element, 'AXChildren') or []:
        yield from walk(child, depth + 1, limit, seen)


def app(pid):
    return AX.AXUIElementCreateApplication(pid)


def dump(pid, depth_limit=14):
    """A small text outline of the whole tree, for the evidence folder."""
    lines = []
    for element, depth in walk(app(pid), limit=depth_limit):
        if depth == 0:
            continue
        lines.append('%s%s title=%r value=%r desc=%r frame=%s' % (
            '  ' * depth, value(element, 'AXRole'), value(element, 'AXTitle'),
            str(value(element, 'AXValue'))[:40], value(element, 'AXDescription'), frame(element)))
    return '\n'.join(lines)


def items(pid):
    """Open menu lines: title, mark, frame, element."""
    out = []
    for element, _ in walk(app(pid)):
        if value(element, 'AXRole') == 'AXMenuItem':
            out.append({'title': value(element, 'AXTitle'), 'mark': value(element, 'AXMenuItemMarkChar'),
                        'frame': frame(element), 'element': element})
    return out


def item(pid, title):
    for line in items(pid):
        if line['title'] == title and line['frame'] and line['frame'][2] > 0:
            return line
    return None


def press(element):
    return AX.AXUIElementPerformAction(element, 'AXPress') == 0


def inside(inner, outer):
    cx, cy = inner[0] + inner[2] / 2, inner[1] + inner[3] / 2
    return outer[0] <= cx <= outer[0] + outer[2] and outer[1] <= cy <= outer[1] + outer[3]


def controls(pid, box, roles=('AXMenuButton', 'AXPopUpButton', 'AXButton')):
    """Elements of those roles whose middle is inside `box` ([x, y, w, h])."""
    out = []
    for element, _ in walk(app(pid)):
        if value(element, 'AXRole') in roles:
            f = frame(element)
            if f and f[2] > 0 and inside(f, box):
                out.append({'role': value(element, 'AXRole'), 'frame': f, 'element': element,
                            'title': value(element, 'AXTitle'), 'desc': value(element, 'AXDescription')})
    return out


def texts(pid, box):
    out = []
    for element, _ in walk(app(pid)):
        if value(element, 'AXRole') == 'AXStaticText':
            f = frame(element)
            if f and f[2] > 0 and inside(f, box):
                out.append({'text': value(element, 'AXValue'), 'frame': f})
    return out


def actions(element):
    err, names = AX.AXUIElementCopyActionNames(element, None)
    return list(names) if err == 0 and names else []


def show_menu(element):
    """Open a menu button's menu: AXShowMenu where it has it, else AXPress."""
    for name in ('AXShowMenu', 'AXPress'):
        if name in actions(element) and AX.AXUIElementPerformAction(element, name) == 0:
            return name
    return None


def hover(x, y, steps=8):
    """The real pointer glides to (x, y): a submenu opens under it."""
    here = Quartz.CGEventGetLocation(Quartz.CGEventCreate(None))
    for i in range(1, steps + 1):
        point = (here.x + (x - here.x) * i / steps, here.y + (y - here.y) * i / steps)
        event = Quartz.CGEventCreateMouseEvent(None, Quartz.kCGEventMouseMoved, point, 0)
        Quartz.CGEventPost(Quartz.kCGHIDEventTap, event)
        time.sleep(0.02)


def open_submenu(pid, title, probe, log):
    """Open the submenu of the menu line `title`; `probe` is a line that shows once it is open."""
    line = item(pid, title)
    if not line:
        raise RuntimeError('no menu line ' + title)
    log['actions'] = actions(line['element'])
    for name in ('AXOpen', 'AXShowMenu'):
        if name in log['actions']:
            AX.AXUIElementPerformAction(line['element'], name)
            for _ in range(10):
                time.sleep(0.15)
                if item(pid, probe):
                    log['opened_by'] = name
                    return True
    f = line['frame']
    hover(f[0] + f[2] / 2, f[1] + f[3] / 2)
    for _ in range(15):
        time.sleep(0.15)
        if item(pid, probe):
            log['opened_by'] = 'pointer'
            return True
    return False


def popover_box(pid):
    """The actual popover, never a similarly sized native menu window."""
    for element, _ in walk(app(pid)):
        if value(element, 'AXRole') == 'AXPopover':
            box = frame(element)
            if box and box[2] > 0 and box[3] > 0:
                return box
    return None


def cancel_menus(pid):
    """Dismiss tracked native menus before closing or reopening their popover."""
    for _ in range(3):
        visible = []
        for element, _ in walk(app(pid)):
            if value(element, 'AXRole') in ('AXMenu', 'AXMenuItem'):
                box = frame(element)
                if box and box[2] > 0 and box[3] > 0:
                    visible.append(element)
        if not visible:
            return
        for element in reversed(visible):
            if 'AXCancel' in actions(element) and AX.AXUIElementPerformAction(element, 'AXCancel') == 0:
                break
        else:
            # Address only this probe process, even beneath adhd's blackout.
            for down in (True, False):
                event = Quartz.CGEventCreateKeyboardEvent(None, 53, down)
                Quartz.CGEventPostToPid(pid, event)
        time.sleep(.2)
