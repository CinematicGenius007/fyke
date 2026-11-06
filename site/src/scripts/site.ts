// The page's behavior. Everything here is an enhancement: with scripts off the
// page reads and links work, in the edition the system asks for.

const root = document.documentElement;
const live = document.getElementById("live");
const say = (text: string) => { if (live) { live.textContent = ""; setTimeout(() => (live.textContent = text), 20); } };

// ----- date: the edition is today's
const fmt = new Intl.DateTimeFormat("en-GB", { weekday: "long", day: "numeric", month: "long", year: "numeric" });
const parts = Object.fromEntries(fmt.formatToParts(new Date()).map((p) => [p.type, p.value]));
const today = `${parts.weekday}, ${parts.day} ${parts.month} ${parts.year}`;
document.querySelectorAll("[data-date]").forEach((el) => (el.textContent = today));

// ----- day and night edition
const radios = Array.from(document.querySelectorAll<HTMLInputElement>('#edition input[name="edition"]'));
const edName = document.getElementById("edition-name");
const night = () => root.dataset.theme === "night";
const syncToggle = () => {
  radios.forEach((r) => (r.checked = r.value === (night() ? "night" : "day")));
  if (edName) edName.textContent = night() ? "Night" : "Local";
};
function setEdition(next: "day" | "night") {
  if (next === "night") root.dataset.theme = "night"; else delete root.dataset.theme;
  try { localStorage.setItem("weir-edition", next); } catch { /* private mode */ }
  syncToggle();
  say(next === "night" ? "Night edition" : "Day edition");
}
syncToggle();
radios.forEach((r) => r.addEventListener("change", () => r.checked && setEdition(r.value as "day" | "night")));
matchMedia("(prefers-color-scheme: dark)").addEventListener("change", (e) => {
  let saved: string | null = null;
  try { saved = localStorage.getItem("weir-edition"); } catch { /* ignore */ }
  if (!saved) { if (e.matches) root.dataset.theme = "night"; else delete root.dataset.theme; syncToggle(); }
});

// ----- slim masthead once the full one has scrolled away
const slim = document.getElementById("slim");
const mast = document.querySelector(".masthead");
if (slim && mast && "IntersectionObserver" in window) {
  new IntersectionObserver(([entry]) => {
    const on = !entry.isIntersecting && entry.boundingClientRect.top < 0;
    slim.classList.toggle("on", on);
    slim.setAttribute("aria-hidden", String(!on));
    slim.querySelectorAll("a").forEach((a) => a.setAttribute("tabindex", on ? "0" : "-1"));
  }).observe(mast);
}

// ----- ribbon: images off by default
const ribbon = document.getElementById("ribbon") as HTMLButtonElement | null;
const inset = document.getElementById("inset");
const imgSwitch = document.getElementById("img-switch") as HTMLInputElement | null;
const ph = document.getElementById("ph");
const what = document.getElementById("what");
function setRibbon(open: boolean, focus = false) {
  if (!ribbon || !inset) return;
  ribbon.setAttribute("aria-expanded", String(open));
  inset.classList.toggle("open", open);
  if (open) { inset.removeAttribute("hidden"); if (focus) imgSwitch?.focus(); }
  else if (focus) ribbon.focus();
}
ribbon?.addEventListener("click", () => setRibbon(ribbon.getAttribute("aria-expanded") !== "true", true));
imgSwitch?.addEventListener("change", () => {
  const on = imgSwitch.checked;
  ph?.classList.toggle("loaded", on);
  const s = document.getElementById("switch-state");
  if (s) s.textContent = on ? "On. Now the publisher's server would see this request." : "Off. Try it: flip to see what changes.";
  if (what) what.innerHTML = on
    ? "Now the publisher's server would see this request. <em>That is the only thing the switch changes.</em>"
    : "With images off, reading an article loads nothing from the publisher. <em>Publishers cannot see you read until you turn images on.</em>";
});

// ----- install: copy, and press feedback
const commands = document.getElementById("commands");
async function copyCommands() {
  if (!commands) return;
  const text = Array.from(commands.querySelectorAll("[data-line]")).map((l) => (l as HTMLElement).dataset.line).join("\n");
  const btn = document.querySelector<HTMLButtonElement>("[data-copy]");
  try {
    await navigator.clipboard.writeText(text);
    if (btn) { btn.textContent = "✓ Copied"; setTimeout(() => (btn.textContent = "Copy"), 2000); }
    say("Commands copied");
  } catch {
    const range = document.createRange();
    range.selectNodeContents(commands);
    const sel = getSelection(); sel?.removeAllRanges(); sel?.addRange(range);
    if (btn) { btn.textContent = "Press ⌘C"; setTimeout(() => (btn.textContent = "Copy"), 2500); }
    say("Select and copy the commands");
  }
}
document.querySelectorAll("[data-copy]").forEach((b) => b.addEventListener("click", copyCommands));

// ----- the install sheet slides in once, when it arrives or is scrolled to
const installSection = document.getElementById("install");
const reduce = matchMedia("(prefers-reduced-motion: reduce)").matches;
let slid = false;
function slideInstall() {
  const sheet = installSection?.querySelector<HTMLElement>(".classifieds");
  if (slid || !sheet || reduce) return;
  slid = true;
  sheet.animate?.(
    [{ transform: "translateX(40px) rotate(-2.5deg)", opacity: 0.4 }, { transform: "none", opacity: 1 }],
    { duration: 420, easing: "cubic-bezier(.2,.8,.2,1)" },
  );
}
if (installSection && "IntersectionObserver" in window) {
  new IntersectionObserver((entries) => entries.forEach((e) => e.isIntersecting && (slideInstall(), true)), { threshold: 0.25 }).observe(installSection);
}
document.querySelectorAll<HTMLAnchorElement>("a[data-get-started]").forEach((a) =>
  a.addEventListener("click", () => {
    if (!installSection) return;
    installSection.setAttribute("tabindex", "-1");
    setTimeout(() => installSection.focus({ preventScroll: true }), 450);
  }),
);

// ----- shortcuts dialog
const keys = document.getElementById("keys") as HTMLDialogElement | null;
let before: HTMLElement | null = null;
function openKeys() { if (!keys || keys.open) return; before = document.activeElement as HTMLElement; keys.showModal(); }
function closeKeys() { keys?.close(); before?.focus(); }
document.querySelectorAll("[data-open-keys]").forEach((a) => a.addEventListener("click", (e) => { e.preventDefault(); openKeys(); }));
keys?.querySelector("[data-close-keys]")?.addEventListener("click", closeKeys);
keys?.addEventListener("click", (e) => { if (e.target === keys) closeKeys(); });

// ----- keyboard: the same keys as the app
const stories = () => Array.from(document.querySelectorAll<HTMLElement>("[data-story]"));
stories().forEach((s) => { if (!s.hasAttribute("href")) s.tabIndex = -1; });
let at = -1;
function focusStory(i: number) {
  const list = stories();
  if (!list.length) return;
  at = Math.max(0, Math.min(list.length - 1, i));
  list.forEach((s) => s.classList.remove("story-focus"));
  const el = list[at];
  el.classList.add("story-focus");
  el.focus({ preventScroll: true });
  const rect = el.getBoundingClientRect();
  const top = scrollY + rect.top - innerHeight * 0.3;
  scrollTo({ top, behavior: matchMedia("(prefers-reduced-motion: reduce)").matches ? "auto" : "smooth" });
}
let lastG = 0;
addEventListener("keydown", (e) => {
  const t = e.target as HTMLElement;
  if (t.closest("input, textarea, select, [contenteditable]")) return;
  if (e.metaKey || e.ctrlKey || e.altKey) return;
  if (keys?.open) { if (e.key === "?") { e.preventDefault(); closeKeys(); } return; }
  switch (e.key) {
    case "j": focusStory(at + 1); break;
    case "k": focusStory(at < 0 ? 0 : at - 1); break;
    case "o": case "Enter": {
      const el = stories()[at];
      if (el && (e.key === "o" || t === el)) { e.preventDefault(); (el as HTMLAnchorElement).click?.(); }
      break;
    }
    case "t": setEdition(night() ? "day" : "night"); break;
    case "i": if (ribbon) { ribbon.scrollIntoView({ block: "center" }); setRibbon(ribbon.getAttribute("aria-expanded") !== "true", true); } break;
    case "c": if (commands) copyCommands(); break;
    case "?": e.preventDefault(); openKeys(); break;
    case "Escape":
      if (ribbon?.getAttribute("aria-expanded") === "true") setRibbon(false, true);
      else { stories().forEach((s) => s.classList.remove("story-focus")); at = -1; }
      break;
    case "g":
      if (Date.now() - lastG < 800) { scrollTo({ top: 0 }); lastG = 0; } else lastG = Date.now();
      break;
  }
});
