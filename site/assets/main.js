// voice-control product page · 動き：スクロールで現れる／しくみのタブの自動送り／試すコンソール（打ち込み）。外部の通信・解析は、ありません。
(() => {
  "use strict";
  const reduced = window.matchMedia("(prefers-reduced-motion: reduce)").matches;
  const $ = (sel, root = document) => root.querySelector(sel);
  const $$ = (sel, root = document) => Array.from(root.querySelectorAll(sel));

  // ── スクロールで現れる ───────────────────────────────
  const reveals = $$(".reveal");
  if (reduced || !("IntersectionObserver" in window)) {
    reveals.forEach((el) => el.classList.add("is-in"));
  } else {
    const io = new IntersectionObserver((entries) => {
      for (const e of entries) if (e.isIntersecting) { e.target.classList.add("is-in"); io.unobserve(e.target); }
    }, { rootMargin: "0px 0px -8% 0px", threshold: 0.08 });
    reveals.forEach((el) => io.observe(el));
  }

  // ── 動画：画面の外では止める。動きを減らす設定なら、自動再生せず、操作できるようにする ─────────────
  const videos = $$("video");
  if (reduced) {
    videos.forEach((v) => { v.pause(); v.removeAttribute("autoplay"); v.controls = true; });
  } else if ("IntersectionObserver" in window) {
    const vio = new IntersectionObserver((entries) => {
      for (const e of entries) {
        if (e.isIntersecting) { const p = e.target.play(); if (p && p.catch) p.catch(() => {}); } else e.target.pause();
      }
    }, { threshold: 0.2 });
    videos.forEach((v) => vio.observe(v));
  }

  // ── コピー ───────────────────────────────────────
  $$("button[data-copy-from]").forEach((btn) => {
    const source = document.getElementById(btn.dataset.copyFrom);
    let timer = 0;
    btn.addEventListener("click", async () => {
      const text = source ? source.textContent.trim() : "";
      try {
        if (navigator.clipboard && window.isSecureContext) await navigator.clipboard.writeText(text);
        else {
          const ta = document.createElement("textarea");
          ta.value = text; ta.setAttribute("readonly", ""); ta.style.position = "fixed"; ta.style.opacity = "0";
          document.body.appendChild(ta); ta.select(); document.execCommand("copy"); ta.remove();
        }
        btn.textContent = "コピーした"; btn.classList.add("is-done");
      } catch (_) { btn.textContent = "選んで ⌘C"; }
      clearTimeout(timer);
      timer = setTimeout(() => { btn.textContent = "コピー"; btn.classList.remove("is-done"); }, 1800);
    });
  });

  // ── しくみ：タブ（自動で送る。触ったら、その人の操作を優先する） ─────────────
  const root = $("#how-tabs");
  if (root) {
    const tabs = $$(".step", root);
    const imgs = $$(".stage-imgs img", root);
    const STEP_MS = 5200;
    let index = 0, timer = 0, userTouched = false, visible = false;
    const show = (i) => {
      index = (i + tabs.length) % tabs.length;
      tabs.forEach((t, k) => {
        const on = k === index;
        t.setAttribute("aria-selected", on ? "true" : "false");
        t.tabIndex = on ? 0 : -1;
        // バーのアニメーションを、頭から
        if (on) { const bar = $(".step-bar", t); bar.style.animation = "none"; void bar.offsetWidth; bar.style.animation = ""; }
      });
      imgs.forEach((img, k) => img.classList.toggle("is-on", k === index));
    };
    const schedule = () => {
      clearTimeout(timer);
      if (reduced || userTouched || !visible) return;
      timer = setTimeout(() => { show(index + 1); schedule(); }, STEP_MS);
    };
    tabs.forEach((t, k) => {
      t.addEventListener("click", () => { userTouched = true; clearTimeout(timer); root.classList.add("is-paused"); show(k); });
      t.addEventListener("keydown", (e) => {
        const next = e.key === "ArrowDown" || e.key === "ArrowRight" ? 1 : e.key === "ArrowUp" || e.key === "ArrowLeft" ? -1 : 0;
        if (!next) return;
        e.preventDefault(); userTouched = true; clearTimeout(timer); root.classList.add("is-paused");
        show(index + next); tabs[index].focus();
      });
    });
    root.addEventListener("pointerenter", () => { if (!userTouched) { clearTimeout(timer); root.classList.add("is-paused"); } });
    root.addEventListener("pointerleave", () => { if (!userTouched) { root.classList.remove("is-paused"); show(index); schedule(); } });
    if (reduced) root.classList.add("is-paused");
    show(0);
    if ("IntersectionObserver" in window) {
      new IntersectionObserver((entries) => {
        visible = entries[0].isIntersecting;
        if (visible) { if (!userTouched) { show(index); schedule(); } } else clearTimeout(timer);
      }, { threshold: 0.35 }).observe(root);
    }
  }

  // ── 試す：本物の `vc run --dry-run` の出力（パスは短縮） ─────────────────
  const SK = "~/.voice-control/skills/";
  const demos = [
    { say: "音量を50にして", lines: [["skill", "spotify", "90.2%（0.1 秒）"], ["cmd", `osascript ${SK}spotify/spotify.applescript volume 50`]] },
    { say: "お気に入りの曲をかけて", lines: [["skill", "spotify", "99.7%（0.1 秒）"], ["cmd", `osascript ${SK}spotify/spotify.applescript play-liked`]] },
    { say: "Amazonでマウスを検索して", lines: [["skill", "web-search", "99.2%（0.1 秒）"], ["cmd", `node ${SK}web-search/web-search.mjs amazon "マウス"`]] },
    { say: "クロードでRustの所有権を調べて", lines: [["skill", "ask-agent", "98.9%（0.1 秒）"], ["cmd", `node ${SK}ask-agent/ask-agent.mjs claude "Rustの所有権"`]] },
    { say: "コピーした文章を要約して", lines: [["skill", "clipboard-note", "100.0%（0.1 秒）"], ["cmd", "pbpaste"]] },
    { say: "Safariを開いて", lines: [["dim", "Tiny-Jev  どのスキルでもない → 既定スキル default（0.4 秒）"], ["cmd", "open -a Safari"]] },
    { say: "クロードでRustの所有権を調べて、そのあとSpotifyで次の曲にして", label: "調べて、そのあと次の曲（複数ステップ）", lines: [
      ["dim", "手順  2 つに分けました"], ["dim", "  1. クロードでRustの所有権を調べて"], ["dim", "  2. Spotifyで次の曲にして"],
      ["step", "▶ ステップ 1/2"], ["skill", "ask-agent", "98.9%（0.1 秒）"], ["cmd", `node ${SK}ask-agent/ask-agent.mjs claude "Rustの所有権"`],
      ["step", "▶ ステップ 2/2"], ["skill", "spotify", "99.5%（0.2 秒）"], ["cmd", `osascript ${SK}spotify/spotify.applescript next`] ] },
  ];
  const chips = $("#chips"), out = $("#console");
  if (chips && out) {
    const esc = (s) => s.replace(/[&<>]/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;" }[c]));
    const render = (d, upto) => {
      // upto：ここまでの文字数（コマンド行だけ、打ち込む）
      let html = `<span class="c-cmd">vc run "${esc(d.say)}" --dry-run</span>\n`;
      let budget = upto;
      for (const line of d.lines) {
        const [kind, a, b] = line;
        if (kind === "cmd") {
          const text = a.slice(0, Math.max(0, budget));
          budget -= a.length;
          html += `<span class="c-cmd">${esc(text)}</span>` + (budget < 0 ? `<span class="caret"></span>` : "") + "\n";
          if (budget < 0) return html;
        } else {
          if (budget < 0) return html;
          if (kind === "skill") html += `<span class="c-skill">Tiny-Jev  <b>${esc(a)}</b>  ${esc(b)}</span>\n`;
          else if (kind === "step") html += `<span class="c-step">${esc(a)}</span>\n`;
          else html += `<span class="c-dim">${esc(a)}</span>\n`;
        }
      }
      return html + `<span class="c-dim">（--dry-run：実行はしません）</span>`;
    };
    let current = -1, tick = 0, auto = 0, touched = false, seen = false;
    const play = (i) => {
      current = i;
      $$("button", chips).forEach((b, k) => b.setAttribute("aria-pressed", k === i ? "true" : "false"));
      clearInterval(tick);
      const d = demos[i];
      const total = d.lines.filter((l) => l[0] === "cmd").reduce((n, l) => n + l[1].length, 0);
      if (reduced) { out.innerHTML = render(d, total + 1); return; }
      let n = 0;
      out.innerHTML = render(d, 0);
      tick = setInterval(() => {
        n += 3;
        out.innerHTML = render(d, n);
        if (n > total) { clearInterval(tick); out.innerHTML = render(d, total + 1); }
      }, 22);
    };
    demos.forEach((d, i) => {
      const li = document.createElement("li");
      const b = document.createElement("button");
      b.type = "button"; b.className = "chip"; b.textContent = d.label || d.say;
      b.title = d.say; b.setAttribute("aria-pressed", "false");
      b.addEventListener("click", () => { touched = true; clearInterval(auto); play(i); });
      li.appendChild(b); chips.appendChild(li);
    });
    play(0);
    if (!reduced && "IntersectionObserver" in window) {
      new IntersectionObserver((entries) => {
        if (entries[0].isIntersecting && !touched && !seen) {
          seen = true;
          auto = setInterval(() => { if (touched) return clearInterval(auto); play((current + 1) % demos.length); }, 5200);
        } else if (!entries[0].isIntersecting) { clearInterval(auto); seen = false; }
      }, { threshold: 0.4 }).observe(out);
    }
  }
})();
