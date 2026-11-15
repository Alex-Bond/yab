(function () {
  "use strict";

  // The product picture keeps its proportions in any window.
  var wrap = document.getElementById("stage-wrap");
  var stage = document.getElementById("stage");
  function fit() {
    if (!wrap || !stage) return;
    var s = Math.min(1, (wrap.clientWidth - 128) / 624, (wrap.clientHeight - 16) / 544);
    stage.style.setProperty("--s", Math.max(0.5, s).toFixed(3));
  }
  fit();
  window.addEventListener("resize", fit);

  // A button that is working says so.
  document.addEventListener("submit", function (e) {
    var form = e.target;
    if (!form.hasAttribute("data-busy-form") || e.defaultPrevented) return;
    var button = e.submitter && e.submitter.classList.contains("btn") ? e.submitter : form.querySelector(".btn-primary");
    if (button) button.setAttribute("aria-busy", "true");
  });
  window.addEventListener("pageshow", function () {
    document.querySelectorAll('[aria-busy="true"]').forEach(function (b) { b.removeAttribute("aria-busy"); });
  });

  // An email the server didn't know is marked until it is changed.
  document.querySelectorAll('.input[aria-invalid="true"]').forEach(function (input) {
    input.addEventListener("input", function () { input.setAttribute("aria-invalid", "false"); }, { once: true });
  });

  // Six boxes, a digit each.
  var verify = document.getElementById("verify");
  if (verify) {
    var boxes = [].slice.call(verify.querySelectorAll(".otp-box"));
    var joined = verify.querySelector('input[name="code"]');

    var sync = function () {
      boxes.forEach(function (b) { b.classList.toggle("filled", !!b.value); });
      joined.value = boxes.map(function (b) { return b.value; }).join("");
    };
    // To a box: its digit selected, so typing replaces it, unless the code
    // is whole, when the caret just rests at the end.
    var go = function (i) {
      var b = boxes[i];
      b.focus();
      if (boxes.every(function (x) { return x.value; })) b.setSelectionRange(b.value.length, b.value.length);
      else b.select();
    };
    var clearError = function () {
      var alert = verify.querySelector(".alert");
      if (alert) alert.remove();
    };
    // Digits from box `at` on; the caret goes to the box after the last.
    var spread = function (at, digits) {
      digits = (digits || "").replace(/\D/g, "");
      if (!digits) return;
      if (digits.length >= boxes.length) at = 0;
      for (var i = 0; i < digits.length && at + i < boxes.length; i++) boxes[at + i].value = digits[i];
      clearError();
      sync();
      go(Math.min(at + digits.length, boxes.length - 1));
    };

    boxes.forEach(function (box, i) {
      // A digit into an empty or selected box goes in as typed; anything
      // the box's one place would refuse is spread by hand.
      box.addEventListener("beforeinput", function (e) {
        if (e.inputType !== "insertText" || e.data == null) return;
        var room = !box.value || box.selectionStart !== box.selectionEnd;
        if (room && /^\d$/.test(e.data)) return;
        e.preventDefault();
        spread(i, e.data);
      });
      box.addEventListener("input", function () {
        var digits = box.value.replace(/\D/g, "");
        if (digits.length > 1) { box.value = ""; spread(i, digits); return; }
        box.value = digits;
        sync();
        if (digits) {
          clearError();
          if (i < boxes.length - 1) go(i + 1);
        }
      });
      box.addEventListener("keydown", function (e) {
        if (e.key === "Backspace" && !box.value && i > 0) {
          e.preventDefault();
          boxes[i - 1].value = "";
          boxes[i - 1].focus();
          sync();
        } else if (e.key === "ArrowLeft" && i > 0) {
          e.preventDefault();
          go(i - 1);
        } else if (e.key === "ArrowRight" && i < boxes.length - 1) {
          e.preventDefault();
          go(i + 1);
        }
      });
      box.addEventListener("focus", function () {
        setTimeout(function () { if (document.activeElement === box) go(i); }, 0);
      });
      box.addEventListener("paste", function (e) {
        var text = (e.clipboardData || window.clipboardData).getData("text");
        e.preventDefault();
        spread(i, text);
      });
    });
    sync();

    // A new code, without leaving the page.
    var resend = document.getElementById("resend");
    var notice = document.getElementById("notice");
    var check = '<svg viewBox="0 0 16 16"><path d="m3.5 8.5 3 3 6-7"/></svg>';
    if (notice.textContent.trim()) notice.innerHTML = check + notice.innerHTML;
    var cool = function (seconds) {
      resend.disabled = true;
      var tick = function () {
        if (seconds <= 0) { resend.disabled = false; resend.textContent = "Resend code"; return; }
        resend.textContent = "Resend in " + seconds + "s";
        seconds -= 1;
        setTimeout(tick, 1000);
      };
      tick();
    };
    resend.addEventListener("click", function (e) {
      e.preventDefault();
      if (resend.disabled) return;
      resend.disabled = true;
      fetch("/verify/resend", { method: "POST", headers: { Accept: "application/json" }, credentials: "same-origin" })
        .then(function (r) { return r.json(); })
        .then(function (answer) {
          if (!answer.ok) { location.href = "/login"; return; }
          notice.innerHTML = check + "<span>We sent a new code to " + answer.email.replace(/[<>&]/g, "") + ".</span>";
          boxes.forEach(function (b) { b.value = ""; });
          sync();
          clearError();
          boxes[0].focus();
          cool(30);
        })
        .catch(function () { resend.disabled = false; });
    });
  }

  // How strong a new password is.
  var password = document.querySelector('input[autocomplete="new-password"]');
  var meter = document.querySelector(".meter");
  if (password && meter) {
    var word = document.querySelector(".meter-row b");
    var words = ["", "Weak", "Fair", "Good", "Strong"];
    var rate = function (p) {
      if (!p) return 0;
      if (p.length < 8) return 1;
      var kinds = [/[a-z]/, /[A-Z]/, /\d/, /[^A-Za-z0-9]/].filter(function (r) { return r.test(p); }).length;
      var score = 1 + (p.length >= 12 ? 1 : 0) + (kinds >= 3 ? 1 : 0) + (kinds === 4 || p.length >= 16 ? 1 : 0);
      return Math.min(4, score);
    };
    var show = function () {
      var score = rate(password.value);
      meter.setAttribute("data-score", score);
      word.setAttribute("data-score", score);
      word.textContent = password.value.length && password.value.length < 8 ? "Too short" : words[score];
    };
    password.addEventListener("input", show);
    password.addEventListener("change", show);
    show();
  }
})();
