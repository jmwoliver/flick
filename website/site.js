// Install command + the hero animation. No dependencies.
(function () {
  "use strict";
  var $ = function (id) { return document.getElementById(id); };

  // Install command: show this site's own domain, and make Copy work.
  var code = $("install-command");
  var copy = $("copy-install");
  if (code && copy) {
    if (location.protocol === "https:") code.textContent = "curl -fsSL " + location.origin + "/install.sh | bash";
    copy.addEventListener("click", function () {
      if (!navigator.clipboard) return;
      navigator.clipboard.writeText(code.textContent).then(function () {
        copy.textContent = "Copied";
        setTimeout(function () { copy.textContent = "Copy"; }, 1500);
      });
    });
  }

  // ───────── Hero animation ─────────
  if (!$("scene")) return;
  var display = $("display"), phone = $("phone"), cursor = $("cursor");
  var f1 = $("f1"), kb = $("kb"), page = $("page"), spaces = $("spaces");
  var pad = phone.querySelector(".pad");
  var typed = $("typed"), caret = $("caret"), menuApp = $("menu-app");
  var winBrowser = $("win-browser"), winNotes = $("win-notes");
  var steps = document.querySelectorAll("#demo-steps li");
  var TEXT = "Call the dentist";

  // Build the iPhone keyboard.
  var rows = [["q","w","e","r","t","y","u","i","o","p"], ["a","s","d","f","g","h","j","k","l"],
              ["⇧","z","x","c","v","b","n","m","⌫"], ["123"," ","return"]];
  var keys = {};
  kb.querySelectorAll(".kb-row").forEach(function (rowEl, i) {
    rows[i].forEach(function (k) {
      var s = document.createElement("span");
      s.textContent = k === " " ? "space" : k;
      if (k === " ") s.className = "mod space";
      else if (k.length > 1 || k === "⇧" || k === "⌫") s.className = "mod";
      rowEl.appendChild(s);
      keys[k] = s;
    });
  });

  function wait(ms) {
    return new Promise(function (resolve) { setTimeout(resolve, ms); }).then(function () {
      // Hold still while the tab is in the background.
      if (!document.hidden) return;
      return new Promise(function (resolve) { document.addEventListener("visibilitychange", resolve, { once: true }); });
    });
  }

  // Move an element to (x%, y%) of its container over `ms`.
  function move(el, x, y, ms) {
    el.style.transitionDuration = el.classList.contains("finger") ? ms + "ms, " + ms + "ms, 150ms, 150ms" : ms + "ms";
    el.style.left = x + "%";
    el.style.top = y + "%";
  }

  // Where an element sits inside a container, as percentages. fx/fy pick the point (0.5 = center).
  function spot(el, within, fx, fy) {
    var a = el.getBoundingClientRect(), b = within.getBoundingClientRect();
    return [(a.left + a.width * fx - b.left) / b.width * 100, (a.top + a.height * fy - b.top) / b.height * 100];
  }

  function step(i) { steps.forEach(function (s, j) { s.classList.toggle("on", i === j); }); }
  function down(f) { f.classList.add("down"); }
  function up(f) { f.classList.remove("down"); }

  function bringToFront(app) {
    var notes = app === "notes";
    winBrowser.classList.toggle("front", !notes);
    winNotes.classList.toggle("front", notes);
    menuApp.textContent = notes ? "Notes" : "Browser";
    $("phone-notes").classList.toggle("front", notes);
    $("phone-browser").classList.toggle("front", !notes);
    var win = notes ? winNotes : winBrowser, icon = notes ? $("mac-notes") : $("mac-browser");
    win.classList.add("pop"); icon.classList.add("bounce");
    setTimeout(function () { win.classList.remove("pop"); icon.classList.remove("bounce"); }, 500);
  }

  var EASE = "cubic-bezier(0.35, 0, 0.25, 1)";

  // Scroll the browser page to `pct` of its height, over `ms` with `ease`.
  function scrollPage(pct, ms, ease) {
    page.style.transition = "transform " + ms + "ms " + (ease || EASE);
    page.style.transform = "translateY(" + pct + "%)";
  }

  // Slide the Mac's Spaces: 0 = first Space, 1 = second.
  function showSpace(n, ms) {
    spaces.style.transition = "transform " + ms + "ms " + EASE;
    spaces.style.transform = "translateX(" + (-100 * n) + "%)";
  }

  function click() {
    var ring = document.createElement("span");
    ring.className = "click-ring";
    ring.style.left = cursor.style.left;
    ring.style.top = cursor.style.top;
    display.appendChild(ring);
    setTimeout(function () { ring.remove(); }, 500);
  }

  function reset() {
    bringToFront("browser");
    scrollPage(0, 0);
    showSpace(0, 0);
    pad.classList.remove("strip-on", "edge-on");
    typed.textContent = "";
    caret.classList.remove("on");
    kb.classList.remove("up");
    cursor.classList.remove("typing");
    up(f1);
  }

  async function run() {
    reset();
    move(cursor, 46, 44, 900);
    step(0);
    await wait(1000);

    // Point and click.
    move(f1, 52, 54, 0); await wait(40); down(f1); await wait(250);
    move(f1, 30, 36, 1000); move(cursor, 22, 30, 1000); await wait(1100);
    move(f1, 60, 58, 1000); move(cursor, 50, 60, 1000); await wait(1100);
    up(f1); await wait(200);
    down(f1); click(); await wait(170); up(f1); await wait(500);

    // Scroll with one hand: thumb up the left-edge strip, then let go and it coasts.
    step(1); await wait(500);
    move(f1, 10, 66, 0); await wait(40);
    down(f1); pad.classList.add("strip-on"); await wait(220);
    move(f1, 10, 42, 480); scrollPage(-16, 480, "linear"); await wait(500);
    up(f1); scrollPage(-46, 1200, "cubic-bezier(0.05, 0.6, 0.2, 1)"); await wait(200);
    pad.classList.remove("strip-on"); await wait(1300);

    // Switch Spaces: slide along the bottom edge. The desktop follows the thumb.
    step(2); await wait(500);
    move(f1, 74, 83.5, 0); await wait(40);
    down(f1); pad.classList.add("edge-on"); await wait(220);
    move(f1, 28, 83.5, 850); showSpace(1, 850); await wait(870);
    up(f1); pad.classList.remove("edge-on"); menuApp.textContent = "Music"; await wait(1500);
    move(f1, 26, 83.5, 0); await wait(40);
    down(f1); pad.classList.add("edge-on"); await wait(220);
    move(f1, 72, 83.5, 850); showSpace(0, 850); await wait(870);
    up(f1); pad.classList.remove("edge-on"); menuApp.textContent = "Browser"; await wait(900);

    // Switch apps: tap Notes in the phone's Dock.
    step(3); await wait(500);
    var icon = $("phone-notes"), p = spot(icon, phone, 0.5, 0.5);
    move(f1, p[0], p[1], 0); await wait(40);
    down(f1); icon.classList.add("pressed"); await wait(170);
    icon.classList.remove("pressed"); up(f1); bringToFront("notes"); await wait(1600);

    // Type: click into the note, and the keyboard opens.
    step(4); await wait(400);
    var t = spot($("note-input"), display, 0, 0.5);
    move(f1, 45, 60, 0); await wait(40); down(f1); await wait(200);
    move(f1, 60, 46, 950); move(cursor, t[0] + 3, t[1] - 1.5, 950); await wait(1050);
    up(f1); await wait(150);
    down(f1); click(); await wait(170); up(f1);
    caret.classList.add("on"); await wait(450);
    kb.classList.add("up"); await wait(650);
    cursor.classList.add("typing");   // macOS hides the pointer while you type
    for (var i = 0; i < TEXT.length; i++) {
      var ch = TEXT[i], key = keys[ch.toLowerCase()];
      if (key) key.classList.add("hit");
      typed.textContent += ch;
      await wait(70);
      if (key) key.classList.remove("hit");
      await wait(ch === " " ? 150 : 60 + Math.random() * 70);
    }
    await wait(1900);
    kb.classList.remove("up"); caret.classList.remove("on");
    await wait(900);
  }

  if (window.matchMedia("(prefers-reduced-motion: reduce)").matches) {
    // A still frame: the note being typed with the phone keyboard open.
    bringToFront("notes");
    typed.textContent = TEXT; caret.classList.add("on"); kb.classList.add("up"); step(4);
    cursor.classList.add("typing");
    var t = spot($("note-input"), display, 0, 0.5);
    move(cursor, t[0] + 3, t[1] - 1.5, 0);
    return;
  }

  (async function loop() { for (;;) await run(); })();
})();
