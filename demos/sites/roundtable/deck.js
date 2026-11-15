// Anna's deck, as someone else's shared screen: slides drawn on a canvas,
// a pointer moving over them, sent as a video stream.

const W = 1280;
const H = 720;
const FONT = 'system-ui, -apple-system, "Helvetica Neue", Arial, sans-serif';
const INK = '#16171a';
const SOFT = '#5d616b';
const FAINT = '#9a9ea7';
const PAPER = '#fbfaf7';
const CORAL = '#ee6a57';
const TINTS = ['#d8f5eb', '#ebe5ff', '#ffe6d6', '#e1eefe'];
const DEEP = ['#1e8f6f', '#6a55d9', '#d0743c', '#3f7fd6'];

function font(size, weight = 400) { return `${weight} ${size}px ${FONT}`; }

function rounded(ctx, x, y, w, h, r) {
  ctx.beginPath();
  ctx.moveTo(x + r, y);
  ctx.arcTo(x + w, y, x + w, y + h, r);
  ctx.arcTo(x + w, y + h, x, y + h, r);
  ctx.arcTo(x, y + h, x, y, r);
  ctx.arcTo(x, y, x + w, y, r);
  ctx.closePath();
}

function frame(ctx, page) {
  ctx.fillStyle = PAPER;
  ctx.fillRect(0, 0, W, H);
  ctx.fillStyle = FAINT;
  ctx.font = font(17, 500);
  ctx.textBaseline = 'alphabetic';
  ctx.textAlign = 'left';
  ctx.fillText('Onboarding v3', 96, 72);
  ctx.textAlign = 'right';
  ctx.fillText(`${page} / 14`, W - 96, H - 52);
  ctx.fillText('Tern · Design', W - 96, 72);
  ctx.textAlign = 'left';
}

function heading(ctx, title, sub) {
  ctx.fillStyle = INK;
  ctx.font = font(50, 700);
  ctx.fillText(title, 96, 162);
  if (sub) {
    ctx.fillStyle = SOFT;
    ctx.font = font(22, 400);
    ctx.fillText(sub, 96, 202);
  }
}

function lines(ctx, x, y, widths, color = 'rgba(22,23,26,0.12)', step = 16, tall = 8) {
  ctx.fillStyle = color;
  widths.forEach((w, i) => { rounded(ctx, x, y + i * step, w, tall, tall / 2); ctx.fill(); });
}

const SLIDES = [
  {
    page: 1,
    draw(ctx) {
      frame(ctx, 1);
      ctx.fillStyle = INK;
      ctx.font = font(92, 750);
      ctx.fillText('Onboarding v3', 96, 330);
      ctx.fillStyle = SOFT;
      ctx.font = font(34, 400);
      ctx.fillText('First run, one question at a time', 98, 388);
      ctx.fillStyle = FAINT;
      ctx.font = font(21, 500);
      ctx.fillText('Anna Ek · Design review', 98, 600);
      // Four cards, fanned: the four new screens.
      const cards = [[860, 150, -7], [905, 205, -2], [950, 262, 3], [995, 320, 8]];
      cards.forEach(([x, y, deg], i) => {
        ctx.save();
        ctx.translate(x + 110, y + 130);
        ctx.rotate((deg * Math.PI) / 180);
        ctx.shadowColor = 'rgba(30, 32, 40, 0.12)';
        ctx.shadowBlur = 30;
        ctx.shadowOffsetY = 12;
        rounded(ctx, -110, -130, 220, 260, 22);
        ctx.fillStyle = '#ffffff';
        ctx.fill();
        ctx.shadowColor = 'transparent';
        rounded(ctx, -110, -130, 220, 96, 22);
        ctx.fillStyle = TINTS[i];
        ctx.fill();
        ctx.fillRect(-110, -60, 220, 26);
        ctx.beginPath();
        ctx.arc(-74, -86, 16, 0, Math.PI * 2);
        ctx.fillStyle = DEEP[i];
        ctx.fill();
        ctx.fillStyle = '#fff';
        ctx.font = font(17, 700);
        ctx.textAlign = 'center';
        ctx.fillText(String(i + 1), -74, -80);
        ctx.textAlign = 'left';
        lines(ctx, -86, -10, [150, 112, 132]);
        rounded(ctx, -86, 74, 172, 34, 17);
        ctx.fillStyle = DEEP[i];
        ctx.fill();
        ctx.restore();
      });
    },
    points: [[420, 330], [1000, 300], [1080, 470]],
  },
  {
    page: 4,
    draw(ctx) {
      frame(ctx, 4);
      heading(ctx, 'Where people leave today', 'Share of new accounts reaching each step, last 30 days');
      const rows = [['Create account', 100], ['Your name', 94], ['Workspace', 82], ['Invite your team', 57], ['Product tour', 51]];
      rows.forEach(([name, value], i) => {
        const y = 272 + i * 74;
        const focus = name === 'Invite your team';
        ctx.fillStyle = focus ? INK : SOFT;
        ctx.font = font(22, focus ? 650 : 500);
        ctx.fillText(name, 96, y + 30);
        rounded(ctx, 360, y, 640, 44, 10);
        ctx.fillStyle = '#eceae4';
        ctx.fill();
        rounded(ctx, 360, y, 640 * value / 100, 44, 10);
        ctx.fillStyle = focus ? CORAL : '#c9ccd3';
        ctx.fill();
        ctx.fillStyle = focus ? CORAL : INK;
        ctx.font = font(22, 700);
        ctx.fillText(`${value}%`, 1020, y + 30);
      });
      ctx.fillStyle = CORAL;
      ctx.font = font(19, 600);
      ctx.fillText('Biggest drop: inviting the team', 760, 248);
    },
    points: [[700, 515], [980, 515], [760, 250]],
  },
  {
    page: 7,
    draw(ctx) {
      frame(ctx, 7);
      heading(ctx, 'The new flow', 'Four screens, one question each, and every step can be skipped');
      const steps = [['Your name', ''], ['Workspace', ''], ['Invite your team', 'Optional'], ['Short tour', 'Skippable']];
      steps.forEach(([name, tag], i) => {
        const x = 96 + i * 279;
        const y = 262;
        ctx.save();
        ctx.shadowColor = 'rgba(30, 32, 40, 0.08)';
        ctx.shadowBlur = 24;
        ctx.shadowOffsetY = 8;
        rounded(ctx, x, y, 250, 340, 22);
        ctx.fillStyle = '#ffffff';
        ctx.fill();
        ctx.restore();
        rounded(ctx, x, y, 250, 120, 22);
        ctx.fillStyle = TINTS[i];
        ctx.fill();
        ctx.fillRect(x, y + 90, 250, 30);
        ctx.beginPath();
        ctx.arc(x + 42, y + 44, 20, 0, Math.PI * 2);
        ctx.fillStyle = DEEP[i];
        ctx.fill();
        ctx.fillStyle = '#fff';
        ctx.font = font(19, 700);
        ctx.textAlign = 'center';
        ctx.fillText(String(i + 1), x + 42, y + 51);
        ctx.textAlign = 'left';
        ctx.fillStyle = INK;
        ctx.font = font(25, 650);
        ctx.fillText(name, x + 24, y + 166);
        if (tag) {
          ctx.font = font(15, 600);
          const tw = ctx.measureText(tag).width + 22;
          rounded(ctx, x + 24, y + 186, tw, 28, 14);
          ctx.fillStyle = TINTS[i];
          ctx.fill();
          ctx.fillStyle = DEEP[i];
          ctx.fillText(tag, x + 35, y + 205);
        }
        lines(ctx, x + 24, y + (tag ? 234 : 196), [190, 150]);
        rounded(ctx, x + 24, y + 282, 202, 38, 19);
        ctx.fillStyle = DEEP[i];
        ctx.fill();
        ctx.fillStyle = '#fff';
        ctx.font = font(16, 650);
        ctx.textAlign = 'center';
        ctx.fillText(i === 3 ? 'Start' : 'Continue', x + 125, y + 306);
        ctx.textAlign = 'left';
      });
    },
    points: [[680, 470], [900, 440], [1030, 560]],
  },
  {
    page: 9,
    draw(ctx) {
      frame(ctx, 9);
      heading(ctx, 'Empty states', 'Projects, inbox and reports, before there is anything in them');
      const names = ['Projects', 'Inbox', 'Reports'];
      names.forEach((name, i) => {
        const x = 96 + i * 372;
        const y = 254;
        rounded(ctx, x, y, 344, 360, 22);
        ctx.fillStyle = '#ffffff';
        ctx.fill();
        ctx.strokeStyle = 'rgba(22,23,26,0.08)';
        ctx.lineWidth = 2;
        ctx.stroke();
        ctx.fillStyle = FAINT;
        ctx.font = font(16, 600);
        ctx.fillText(name, x + 26, y + 40);
        // A small drawing for each.
        const cx = x + 172;
        const cy = y + 150;
        ctx.beginPath();
        ctx.arc(cx, cy, 62, 0, Math.PI * 2);
        ctx.fillStyle = TINTS[i];
        ctx.fill();
        ctx.fillStyle = DEEP[i];
        if (i === 0) {
          rounded(ctx, cx - 34, cy - 24, 68, 50, 8); ctx.fill();
          ctx.fillStyle = TINTS[i]; rounded(ctx, cx - 22, cy - 10, 44, 6, 3); ctx.fill(); rounded(ctx, cx - 22, cy + 4, 30, 6, 3); ctx.fill();
        } else if (i === 1) {
          rounded(ctx, cx - 36, cy - 22, 72, 46, 8); ctx.fill();
          ctx.strokeStyle = TINTS[i]; ctx.lineWidth = 5; ctx.lineJoin = 'round';
          ctx.beginPath(); ctx.moveTo(cx - 30, cy - 14); ctx.lineTo(cx, cy + 6); ctx.lineTo(cx + 30, cy - 14); ctx.stroke();
        } else {
          [26, 46, 34].forEach((bh, k) => { rounded(ctx, cx - 30 + k * 22, cy + 26 - bh, 16, bh, 4); ctx.fill(); });
        }
        ctx.fillStyle = INK;
        ctx.font = font(20, 650);
        ctx.textAlign = 'center';
        ctx.fillText(['No projects yet', 'You are all caught up', 'Reports show up here'][i], cx, y + 262);
        ctx.textAlign = 'left';
        rounded(ctx, cx - 70, y + 292, 140, 36, 18);
        ctx.fillStyle = i === 0 ? DEEP[0] : '#f1efe9';
        ctx.fill();
        ctx.fillStyle = i === 0 ? '#fff' : SOFT;
        ctx.font = font(15, 650);
        ctx.textAlign = 'center';
        ctx.fillText(['New project', 'Open settings', 'Learn more'][i], cx, y + 315);
        ctx.textAlign = 'left';
      });
    },
    points: [[268, 520], [268, 410], [640, 520]],
  },
  {
    page: 13,
    draw(ctx) {
      frame(ctx, 13);
      heading(ctx, 'Next steps', 'Before the build goes out behind a flag');
      const items = [
        ['Cut the second sentence on the projects screen', true],
        ['Truncate long workspace names to one line', false],
        ['Bring skipped invites back as a card on home', false],
        ['Same treatment for the permissions step', false],
        ['Build behind a flag by Thursday', false],
      ];
      items.forEach(([text, done], i) => {
        const y = 268 + i * 72;
        rounded(ctx, 96, y, 34, 34, 9);
        ctx.fillStyle = done ? DEEP[0] : '#ffffff';
        ctx.fill();
        if (!done) { ctx.strokeStyle = '#cfd2d8'; ctx.lineWidth = 2; ctx.stroke(); }
        if (done) {
          ctx.strokeStyle = '#fff'; ctx.lineWidth = 3.5; ctx.lineCap = 'round'; ctx.lineJoin = 'round';
          ctx.beginPath(); ctx.moveTo(104, y + 18); ctx.lineTo(110, y + 24); ctx.lineTo(122, y + 11); ctx.stroke();
        }
        ctx.fillStyle = done ? FAINT : INK;
        ctx.font = font(26, 500);
        ctx.fillText(text, 152, y + 26);
      });
    },
    points: [[420, 300], [610, 372], [560, 588]],
  },
];

// The pointer, drawn the way macOS draws it.
function pointer(ctx, x, y) {
  ctx.save();
  ctx.translate(x, y);
  ctx.beginPath();
  ctx.moveTo(0, 0);
  ctx.lineTo(0, 22);
  ctx.lineTo(5.2, 17);
  ctx.lineTo(9, 25.4);
  ctx.lineTo(12.6, 23.8);
  ctx.lineTo(8.9, 15.6);
  ctx.lineTo(16, 15.6);
  ctx.closePath();
  ctx.shadowColor = 'rgba(0,0,0,0.3)';
  ctx.shadowBlur = 4;
  ctx.shadowOffsetY = 1.5;
  ctx.fillStyle = '#111';
  ctx.fill();
  ctx.shadowColor = 'transparent';
  ctx.strokeStyle = '#fff';
  ctx.lineWidth = 1.6;
  ctx.lineJoin = 'round';
  ctx.stroke();
  ctx.restore();
}

const ease = (k) => (k < 0.5 ? 4 * k * k * k : 1 - Math.pow(-2 * k + 2, 3) / 2);

export function startDeck(host) {
  const canvas = document.createElement('canvas');
  canvas.width = W;
  canvas.height = H;
  host.appendChild(canvas);
  const ctx = canvas.getContext('2d');
  const pages = SLIDES.map((s) => {
    const c = document.createElement('canvas');
    c.width = W;
    c.height = H;
    s.draw(c.getContext('2d'));
    return c;
  });

  const SLIDE_MS = 9000;
  const FADE_MS = 420;
  let index = 0;
  let since = performance.now();
  let from = { x: 640, y: 420 };
  let to = { x: 640, y: 420 };
  let moveAt = since;
  let moveMs = 900;
  let nextMove = since + 1200;
  let point = 0;
  let timer = 0;
  let stopped = false;

  function draw() {
    if (stopped) return;
    const now = performance.now();
    if (now - since > SLIDE_MS) {
      index = (index + 1) % SLIDES.length;
      since = now;
      point = 0;
      nextMove = now + 700;
    }
    const fade = Math.min(1, (now - since) / FADE_MS);
    if (fade < 1) {
      ctx.globalAlpha = 1;
      ctx.drawImage(pages[(index + SLIDES.length - 1) % SLIDES.length], 0, 0);
      ctx.globalAlpha = fade;
    }
    ctx.drawImage(pages[index], 0, 0);
    ctx.globalAlpha = 1;
    if (now > nextMove) {
      const pts = SLIDES[index].points;
      const [x, y] = pts[point % pts.length];
      point += 1;
      from = current();
      to = { x: x + (Math.random() * 30 - 15), y: y + (Math.random() * 20 - 10) };
      moveAt = now;
      moveMs = 700 + Math.random() * 500;
      nextMove = now + moveMs + 1600 + Math.random() * 1600;
    }
    const at = current();
    pointer(ctx, at.x, at.y);
    timer = setTimeout(draw, 66);

    function current() {
      const k = Math.min(1, (performance.now() - moveAt) / moveMs);
      const e = ease(k);
      return { x: from.x + (to.x - from.x) * e, y: from.y + (to.y - from.y) * e };
    }
  }

  draw();
  const stream = typeof canvas.captureStream === 'function' ? canvas.captureStream(15) : null;
  return {
    stream,
    stop() {
      stopped = true;
      clearTimeout(timer);
      if (stream) stream.getTracks().forEach((t) => t.stop());
      canvas.remove();
    },
  };
}
