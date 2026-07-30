"use client";

import React, { useState, useEffect, useRef } from "react";

// Theme definitions matching AppTheme in ProductPreferences.swift
const THEMES = [
  { id: "pristine", name: "純淨 (Pristine)", bg: "bg-slate-900/80", border: "border-slate-700", text: "text-slate-100", accent: "#38bdf8" },
  { id: "studio", name: "設計工房 (Studio)", bg: "bg-[#181614]", border: "border-amber-900/40", text: "text-amber-100", accent: "#fbbf24" },
  { id: "obsidian", name: "曜石 (Obsidian)", bg: "bg-[#0b0f19]", border: "border-slate-800", text: "text-slate-100", accent: "#06b6d4" },
];

// Chrome definitions matching HUDChrome in ProductPreferences.swift
const CHROMES = [
  { id: "borderless", name: "無邊框", desc: "純黑暗夜底盤" },
  { id: "hairline", name: "髮絲細邊", desc: "0.75px 亮點金屬極細邊" },
  { id: "glowEdge", name: "流光邊", desc: "霓虹漸變環繞流光" },
  { id: "breathingRing", name: "呼吸光環", desc: "柔和律動光暈" },
  { id: "naked", name: "超薄無底", desc: "Siri 式 2x 懸浮無邊" },
  { id: "aura", name: "微光流體", desc: "彌散外擴霓虹霧" },
  { id: "emboss", name: "浮雕", desc: "雙重沉降金屬陰影" },
];

// Subtitle styles matching SubtitleStyle in ProductPreferences.swift
const SUBTITLE_STYLES = [
  { id: "bubble", name: "膠囊字幕", text: "NexVoice 本地語音聽寫運算中..." },
  { id: "fluidGlow", name: "流動光暈", text: "熱鍵按下即刻錄音，放開瞬間自動貼上。" },
  { id: "teleprompter", name: "提詞機", text: "100% LOCAL MLX WHISPER DICTATION" },
  { id: "terminal", name: "終端機打字", text: "mlx-community/whisper-large-v3-turbo" },
  { id: "spatialBlur", name: "空間焦距模糊", text: "極速聽寫 · 本地優先 · 零費用隱私" },
];

// 21 Genuinely distinct HUD definitions matching HUDStyle in ProductPreferences.swift
const HUDS = [
  { id: 1, styleKey: "glassBars", name: "亮條", englishName: "Glass Bars", category: "經典光條", desc: "23根高亮白光晶棒，隨聲量波形呼吸中浪" },
  { id: 2, styleKey: "bloomPills", name: "膠囊光暈", englishName: "Bloom Pills", category: "經典光條", desc: "三段彌散圓角膠囊，帶多重波段螢光疊加" },
  { id: 3, styleKey: "plasmaColumns", name: "等離子柱", englishName: "Plasma Columns", category: "經典光條", desc: "青藍與極光紫漸變聲波柱陣列" },
  { id: 4, styleKey: "liquidPulse", name: "液態脈衝", englishName: "Liquid Pulse", category: "經典光條", desc: "中央向兩側擴散的液體擴張律動" },
  { id: 5, styleKey: "auraRibbon", name: "流光絲帶", englishName: "Aura Ribbon", category: "流體絲帶", desc: "雙層流光微光帶交織運動" },
  { id: 6, styleKey: "glass", name: "琉璃", englishName: "Glass", category: "流體絲帶", desc: "經典 3 層諧波平滑正弦波浪" },
  { id: 7, styleKey: "aurora", name: "極光", englishName: "Aurora Bars", category: "極光霓彩", desc: "9 根多彩色相漂移柱，兩端圓弧漸變" },
  { id: 8, styleKey: "siri", name: "光球", englishName: "Siri Orb", category: "球體立體", desc: "三層同心立體光暈球體與高光核心" },
  { id: 9, styleKey: "prismCore", name: "虹核", englishName: "Iris Core", category: "球體立體", desc: "三道彩虹流光交匯於發光高亮核心" },
  { id: 10, styleKey: "ember", name: "赤霞", englishName: "Ember Bars", category: "熾熱火焰", desc: "底層赤紅輻射暈搭配 11 根金黃熱浪柱" },
  { id: 11, styleKey: "comet", name: "彗尾", englishName: "Comet Stream", category: "動態粒子", desc: "無限符號動態彗星軌軌與漸薄藍紫彗尾" },
  { id: 12, styleKey: "helix", name: "雙螺旋", englishName: "Helix Braid", category: "幾何螺旋", desc: "青紫雙股 DNA 螺旋交織與亮點節點" },
  { id: 13, styleKey: "mercury", name: "水銀", englishName: "Mercury Band", category: "流體金屬", desc: "上下鏡射液體金屬帶與白光高光邊緣" },
  { id: 14, styleKey: "plasma", name: "電漿", englishName: "Plasma Arc", category: "高能電漿", desc: "紫羅蘭高壓電弧與內層高亮白色長絲" },
  { id: 15, styleKey: "eclipse", name: "日蝕", englishName: "Eclipse Corona", category: "宇宙氣象", desc: "黑洞暗盤四周爆發 16 道金黃日冕耀斑" },
  { id: 16, styleKey: "smoke", name: "煙霧", englishName: "Smoke Plume", category: "煙霧氣流", desc: "7 個雲霧氣團旋轉篩飾疊加湧動" },
  { id: 17, styleKey: "horizontalSmoke", name: "橫煙", englishName: "Horizontal Smoke", category: "煙霧氣流", desc: "4 層水平橫向平移飄散的紫藍煙流" },
  { id: 18, styleKey: "oceanSwell", name: "海浪", englishName: "Ocean Swell", category: "海洋水體", desc: "3 層海浪波濤堆疊與聲量高光浪花邊" },
  { id: 19, styleKey: "silkStream", name: "絲綢氣流", englishName: "Silk Stream", category: "流體絲帶", desc: "3 道絲綢質地流光帶交錯高光亮點" },
  { id: 20, styleKey: "auroraMist", name: "極光霧", englishName: "Aurora Mist", category: "極光霓彩", desc: "4 層夢幻極光霧簾向下自然渲染" },
  { id: 21, styleKey: "inkBloom", name: "墨滴擴散", englishName: "Ink Bloom", category: "煙霧氣流", desc: "5 朵墨滴在水體中擴散暈染脈動" },
];

/**
 * 21 Distinct Canvas2D renderers faithful to Swift graphics implementations in HUDDesignPack.swift
 */
function drawHUD(
  ctx: CanvasRenderingContext2D,
  hudId: number,
  w: number,
  h: number,
  phase: number,
  level: number
) {
  ctx.clearRect(0, 0, w, h);
  const cx = w / 2;
  const cy = h / 2;
  const plate = w / 156.0;

  switch (hudId) {
    case 1: { // GlassBars (亮條)
      const count = 23;
      const energy = 0.22 + Math.min(1, level) * 0.78;
      const spacing = w / (count + 1);
      const barW = Math.max(2, 2.2 * plate);
      ctx.fillStyle = "rgba(255, 255, 255, 0.96)";
      ctx.shadowColor = "rgba(255, 255, 255, 0.9)";
      ctx.shadowBlur = 4 * plate;
      for (let i = 0; i < count; i++) {
        const u = i / (count - 1);
        const envelope = 0.3 + 0.7 * Math.pow(Math.sin(u * Math.PI), 1.4) + 0.18 * Math.sin(u * Math.PI * 3.1);
        const wobble = 0.5 + 0.5 * Math.sin(phase * 2.4 + i * 0.9) * Math.sin(phase * 1.1 + i * 0.35);
        const amp = Math.max(0.1, envelope * (0.28 + 0.72 * wobble) * energy);
        const barH = Math.max(3, h * 0.75 * amp);
        const x = spacing * (i + 1) - barW / 2;
        const y = cy - barH / 2;
        ctx.beginPath();
        ctx.roundRect(x, y, barW, barH, barW / 2);
        ctx.fill();
      }
      ctx.shadowBlur = 0;
      break;
    }

    case 2: { // BloomPills (膠囊光暈)
      const count = 15;
      const spacing = w / (count + 1);
      const barW = Math.max(2.5, 3.5 * plate);
      for (let i = 0; i < count; i++) {
        const u = i / (count - 1);
        const envelope = Math.sin(u * Math.PI);
        const wave = Math.sin(phase * 2 + i * 0.7) * 0.3 + 0.7;
        const amp = (0.15 + level * 0.85) * envelope * wave;
        const barH = Math.max(4, h * 0.7 * amp);
        const x = spacing * (i + 1) - barW / 2;
        const y = cy - barH / 2;

        ctx.shadowColor = "rgba(56, 189, 248, 0.6)";
        ctx.shadowBlur = (4 + level * 6) * plate;
        ctx.fillStyle = i % 2 === 0 ? "rgba(186, 230, 253, 0.95)" : "rgba(56, 189, 248, 0.9)";
        ctx.beginPath();
        ctx.roundRect(x, y, barW, barH, barW / 2);
        ctx.fill();
      }
      ctx.shadowBlur = 0;
      break;
    }

    case 3: { // PlasmaColumns (等離子柱)
      const count = 17;
      const spacing = w / (count + 1);
      const barW = Math.max(2, 3 * plate);
      for (let i = 0; i < count; i++) {
        const normI = (i - 8) / 8;
        const envelope = Math.cos(normI * Math.PI * 0.45);
        const wave = Math.sin(phase * 2.2 + i * 0.8) * 0.35 + 0.65;
        const amp = (0.12 + level * 0.88) * envelope * wave;
        const barH = Math.max(4, h * 0.78 * amp);
        const x = spacing * (i + 1) - barW / 2;

        const grad = ctx.createLinearGradient(x, cy - barH / 2, x, cy + barH / 2);
        grad.addColorStop(0, "rgba(192, 132, 252, 0.95)");
        grad.addColorStop(0.5, "rgba(56, 189, 248, 0.9)");
        grad.addColorStop(1, "rgba(129, 140, 248, 0.85)");

        ctx.shadowColor = "rgba(168, 85, 247, 0.6)";
        ctx.shadowBlur = 5 * plate;
        ctx.fillStyle = grad;
        ctx.beginPath();
        ctx.roundRect(x, cy - barH / 2, barW, barH, barW / 2);
        ctx.fill();
      }
      ctx.shadowBlur = 0;
      break;
    }

    case 4: { // LiquidPulse (液態脈衝)
      const count = 13;
      const spacing = w / (count + 1);
      for (let i = 0; i < count; i++) {
        const distFromCenter = Math.abs(i - 6) / 6;
        const delay = distFromCenter * 0.8;
        const wave = Math.sin(phase * 3 - delay) * 0.5 + 0.5;
        const radius = Math.max(2, (2 + level * 8) * (1 - distFromCenter * 0.4) * wave);
        const x = spacing * (i + 1);

        ctx.shadowColor = "rgba(45, 212, 191, 0.7)";
        ctx.shadowBlur = 6 * plate;
        ctx.fillStyle = "rgba(153, 246, 228, 0.95)";
        ctx.beginPath();
        ctx.arc(x, cy, radius, 0, Math.PI * 2);
        ctx.fill();
      }
      ctx.shadowBlur = 0;
      break;
    }

    case 5: { // AuraRibbon (流光絲帶)
      for (let r = 0; r < 2; r++) {
        const p = phase * (1.2 + r * 0.4) + r * Math.PI;
        ctx.beginPath();
        for (let x = 0; x <= w; x += 4) {
          const u = x / w;
          const env = Math.sin(u * Math.PI);
          const y = cy + Math.sin(u * 8 + p) * (3 + level * 10) * env;
          if (x === 0) ctx.moveTo(x, y);
          else ctx.lineTo(x, y);
        }
        ctx.strokeStyle = r === 0 ? "rgba(56, 189, 248, 0.85)" : "rgba(244, 114, 182, 0.8)";
        ctx.lineWidth = (2.5 + level * 2) * plate;
        ctx.shadowColor = r === 0 ? "rgba(56, 189, 248, 0.6)" : "rgba(244, 114, 182, 0.6)";
        ctx.shadowBlur = 6 * plate;
        ctx.stroke();
      }
      ctx.shadowBlur = 0;
      break;
    }

    case 6: { // Glass (琉璃)
      const layers = [
        { freq: 5.5, speed: 1.0, phase: 0, amp: 1.0, width: 2.0, color: "rgba(255, 255, 255, 0.95)" },
        { freq: 7.5, speed: -1.3, phase: 1.7, amp: 0.68, width: 1.4, color: "rgba(214, 238, 255, 0.6)" },
        { freq: 3.5, speed: 0.7, phase: 3.1, amp: 0.52, width: 1.2, color: "rgba(161, 196, 255, 0.45)" },
      ];
      const amplitude = (0.05 + level * 0.95) * h * 0.4;
      for (const l of layers) {
        ctx.beginPath();
        for (let x = 0; x <= w; x += 2) {
          const u = x / w;
          const envelope = Math.sin(u * Math.PI);
          const y = cy + amplitude * l.amp * envelope * Math.sin(l.freq * u * Math.PI * 2 + phase * l.speed + l.phase);
          if (x === 0) ctx.moveTo(x, y);
          else ctx.lineTo(x, y);
        }
        ctx.strokeStyle = l.color;
        ctx.lineWidth = l.width * plate;
        ctx.stroke();
      }
      break;
    }

    case 7: { // Aurora (極光)
      const bars = 9;
      const spacing = w / (bars + 1);
      const barW = Math.max(3 * plate, w * 0.045);
      for (let i = 0; i < bars; i++) {
        const x = spacing * (i + 1);
        const mid = (bars - 1) / 2;
        const normI = (i - mid) / mid;
        const wave = Math.sin(phase * 1.5 + i * 0.6) * 0.25 + 0.75;
        const envelope = Math.cos(normI * Math.PI * 0.45);
        const amp = (0.12 + level * 0.88 * wave) * envelope;
        const barH = Math.max(6 * plate, h * 0.75 * amp);

        const hue = (160 + i * 18 + Math.sin(phase + i) * 15) % 360;
        const grad = ctx.createLinearGradient(x, cy - barH / 2, x, cy + barH / 2);
        grad.addColorStop(0, `hsla(${hue}, 100%, 75%, 0.95)`);
        grad.addColorStop(0.5, `hsla(${(hue + 30) % 360}, 95%, 60%, 0.85)`);
        grad.addColorStop(1, `hsla(${(hue + 60) % 360}, 90%, 50%, 0.75)`);

        ctx.shadowColor = `hsla(${hue}, 100%, 65%, 0.6)`;
        ctx.shadowBlur = (4 + level * 4) * plate;
        ctx.fillStyle = grad;
        ctx.beginPath();
        ctx.roundRect(x - barW / 2, cy - barH / 2, barW, barH, barW / 2);
        ctx.fill();
      }
      ctx.shadowBlur = 0;
      break;
    }

    case 8: { // Siri (光球 / DepthOrb)
      const maxR = Math.min(w, h) * 0.42;
      const pulse = Math.sin(phase * 2) * 0.12 + 0.88;
      const baseR = maxR * (0.25 + level * 0.75) * pulse;

      // Outer Halo
      const haloR = baseR * 1.8;
      const haloGrad = ctx.createRadialGradient(cx, cy, 0, cx, cy, Math.max(1, haloR));
      haloGrad.addColorStop(0, `rgba(56, 189, 248, ${0.35 + level * 0.35})`);
      haloGrad.addColorStop(0.6, `rgba(99, 102, 241, ${0.2 + level * 0.2})`);
      haloGrad.addColorStop(1, "rgba(15, 23, 42, 0)");
      ctx.fillStyle = haloGrad;
      ctx.beginPath();
      ctx.arc(cx, cy, Math.max(1, haloR), 0, Math.PI * 2);
      ctx.fill();

      // Body
      const bodyR = Math.max(3, baseR);
      const bodyGrad = ctx.createRadialGradient(cx - bodyR * 0.2, cy - bodyR * 0.2, 0, cx, cy, bodyR);
      bodyGrad.addColorStop(0, "rgb(125, 211, 252)");
      bodyGrad.addColorStop(0.5, "rgb(56, 189, 248)");
      bodyGrad.addColorStop(1, "rgb(30, 64, 175)");
      ctx.shadowColor = "rgba(56, 189, 248, 0.7)";
      ctx.shadowBlur = (6 + level * 6) * plate;
      ctx.fillStyle = bodyGrad;
      ctx.beginPath();
      ctx.arc(cx, cy, bodyR, 0, Math.PI * 2);
      ctx.fill();

      // Specular Core
      const coreR = Math.max(1, bodyR * 0.3);
      ctx.shadowColor = "white";
      ctx.shadowBlur = 3;
      ctx.fillStyle = "white";
      ctx.beginPath();
      ctx.arc(cx - bodyR * 0.15, cy - bodyR * 0.15, coreR, 0, Math.PI * 2);
      ctx.fill();

      ctx.shadowBlur = 0;
      break;
    }

    case 9: { // PrismCore (虹核 / IrisCore)
      for (let k = 0; k < 3; k++) {
        const hue = (phase * 40 + k * 120) % 360;
        ctx.beginPath();
        for (let x = 0; x <= w; x += 4 * plate) {
          const normX = (x - cx) / (w / 2);
          const envelope = Math.exp(-normX * normX * 2.5);
          const y = cy + Math.sin(phase * 2 + normX * 4 + k * 1.5) * (h * 0.32 * level + 2 * plate) * envelope;
          if (x === 0) ctx.moveTo(x, y);
          else ctx.lineTo(x, y);
        }
        ctx.strokeStyle = `hsla(${hue}, 90%, 65%, ${0.5 + level * 0.4})`;
        ctx.lineWidth = 3.5 * plate;
        ctx.shadowColor = `hsla(${hue}, 90%, 60%, 0.8)`;
        ctx.shadowBlur = 4 * plate;
        ctx.stroke();
      }

      const coreR = Math.max(4 * plate, h * 0.22 * (0.3 + level * 0.7));
      const coreGrad = ctx.createRadialGradient(cx, cy, 0, cx, cy, coreR);
      coreGrad.addColorStop(0, "white");
      coreGrad.addColorStop(0.5, "rgba(244, 114, 182, 0.9)");
      coreGrad.addColorStop(1, "rgba(192, 132, 252, 0)");
      ctx.fillStyle = coreGrad;
      ctx.beginPath();
      ctx.arc(cx, cy, coreR, 0, Math.PI * 2);
      ctx.fill();

      ctx.shadowBlur = 0;
      break;
    }

    case 10: { // Ember (赤霞)
      const bgGrad = ctx.createRadialGradient(cx, cy, 0, cx, cy, w * 0.4);
      bgGrad.addColorStop(0, `rgba(249, 115, 22, ${0.25 + level * 0.35})`);
      bgGrad.addColorStop(1, "rgba(0, 0, 0, 0)");
      ctx.fillStyle = bgGrad;
      ctx.fillRect(0, 0, w, h);

      const bars = 11;
      const spacing = w / (bars + 1);
      const barW = Math.max(3.5 * plate, w * 0.04);

      for (let i = 0; i < bars; i++) {
        const x = spacing * (i + 1);
        const normI = (i - 5) / 5;
        const envelope = Math.cos(normI * Math.PI * 0.45);
        const wave = Math.sin(phase * 2 + i * 0.5) * 0.2 + 0.8;
        const amp = (0.1 + level * 0.9) * wave * envelope;
        const barH = Math.max(5 * plate, h * 0.72 * amp);

        const grad = ctx.createLinearGradient(x, cy - barH / 2, x, cy + barH / 2);
        grad.addColorStop(0, "rgb(254, 240, 138)");
        grad.addColorStop(0.4, "rgb(249, 115, 22)");
        grad.addColorStop(1, "rgb(220, 38, 38)");

        ctx.shadowColor = "rgba(249, 115, 22, 0.6)";
        ctx.shadowBlur = (3 + level * 4) * plate;
        ctx.fillStyle = grad;
        ctx.beginPath();
        ctx.roundRect(x - barW / 2, cy - barH / 2, barW, barH, barW / 2);
        ctx.fill();
      }
      ctx.shadowBlur = 0;
      break;
    }

    case 11: { // Comet (彗尾)
      const reach = w * 0.35 * (0.2 + level * 0.8);
      const lift = h * 0.2 * (0.2 + level * 0.8);
      const getPos = (p: number) => ({
        x: cx + Math.sin(p * 1.8) * reach,
        y: cy + Math.cos(p * 2.4) * lift,
      });

      const head = getPos(phase);
      const points = 24;
      ctx.beginPath();
      for (let i = 0; i < points; i++) {
        const t = i / (points - 1);
        const pos = getPos(phase - t * 0.8);
        if (i === 0) ctx.moveTo(pos.x, pos.y);
        else ctx.lineTo(pos.x, pos.y);
      }

      const grad = ctx.createLinearGradient(head.x, head.y, cx, cy);
      grad.addColorStop(0, "rgba(56, 189, 248, 0.95)");
      grad.addColorStop(0.5, "rgba(129, 140, 248, 0.6)");
      grad.addColorStop(1, "rgba(99, 102, 241, 0)");

      ctx.strokeStyle = grad;
      ctx.lineWidth = (4 + level * 4) * plate;
      ctx.shadowColor = "rgba(56, 189, 248, 0.7)";
      ctx.shadowBlur = 5 * plate;
      ctx.stroke();

      const headR = Math.max(3 * plate, (4 + level * 3) * plate);
      ctx.fillStyle = "white";
      ctx.shadowColor = "white";
      ctx.shadowBlur = 6 * plate;
      ctx.beginPath();
      ctx.arc(head.x, head.y, headR, 0, Math.PI * 2);
      ctx.fill();

      ctx.shadowBlur = 0;
      break;
    }

    case 12: { // Helix (雙螺旋)
      const points = 32;
      const step = w / (points - 1);

      for (let strand = 0; strand < 2; strand++) {
        const offset = strand * Math.PI;
        const color = strand === 0 ? "rgb(56, 189, 248)" : "rgb(192, 132, 252)";
        const shadowColor = strand === 0 ? "rgba(56, 189, 248, 0.7)" : "rgba(192, 132, 252, 0.7)";

        const getY = (x: number) => {
          const normX = (x - w / 2) / (w / 2);
          const envelope = Math.cos(normX * Math.PI * 0.45);
          return cy + Math.sin(phase * 2 + normX * 3 + offset) * (h * 0.36 * (0.15 + level * 0.85)) * envelope;
        };

        ctx.beginPath();
        for (let i = 0; i < points; i++) {
          const x = i * step;
          const y = getY(x);
          if (i === 0) ctx.moveTo(x, y);
          else ctx.lineTo(x, y);
        }

        ctx.strokeStyle = color;
        ctx.lineWidth = (3.5 + level * 2) * plate;
        ctx.shadowColor = shadowColor;
        ctx.shadowBlur = (4 + level * 3) * plate;
        ctx.stroke();

        for (let i = 2; i < points - 2; i += 5) {
          const x = i * step;
          const r = (2.2 + level * 1.2) * plate;
          ctx.fillStyle = "white";
          ctx.beginPath();
          ctx.arc(x, getY(x), r, 0, Math.PI * 2);
          ctx.fill();
        }
      }
      ctx.shadowBlur = 0;
      break;
    }

    case 13: { // Mercury (水銀)
      const steps = 30;
      const stepW = w / steps;

      const getOffset = (x: number) => {
        const normX = (x - w / 2) / (w / 2);
        const envelope = Math.cos(normX * Math.PI * 0.4);
        const wave = Math.sin(phase * 1.6 + normX * 2.5) * Math.cos(phase * 0.9 + normX * 1.2);
        return Math.abs(wave) * (4 * plate + level * (h * 0.36)) * envelope;
      };

      ctx.beginPath();
      ctx.moveTo(0, cy);
      for (let i = 0; i <= steps; i++) {
        const x = i * stepW;
        ctx.lineTo(x, cy - getOffset(x) - 2 * plate);
      }
      for (let i = steps; i >= 0; i--) {
        const x = i * stepW;
        ctx.lineTo(x, cy + getOffset(x) + 2 * plate);
      }
      ctx.closePath();

      const grad = ctx.createLinearGradient(0, 0, w, h);
      grad.addColorStop(0, "rgb(226, 232, 240)");
      grad.addColorStop(0.3, "rgb(148, 163, 184)");
      grad.addColorStop(0.7, "rgb(203, 213, 225)");
      grad.addColorStop(1, "rgb(100, 116, 139)");

      ctx.shadowColor = "rgba(226, 232, 240, 0.5)";
      ctx.shadowBlur = (4 + level * 3) * plate;
      ctx.fillStyle = grad;
      ctx.fill();

      ctx.strokeStyle = "white";
      ctx.lineWidth = 1.8 * plate;
      ctx.stroke();

      ctx.shadowBlur = 0;
      break;
    }

    case 14: { // Plasma (電漿)
      ctx.beginPath();
      for (let x = 0; x <= w; x += 3 * plate) {
        const normX = (x - w / 2) / (w / 2);
        const envelope = Math.exp(-normX * normX * 3);
        const swing = Math.sin(phase * 3 + normX * 5) * 8 * plate + Math.cos(phase * 2 - normX * 8) * 6 * plate;
        const y = cy + swing * (0.2 + level * 0.8) * envelope;
        if (x === 0) ctx.moveTo(x, y);
        else ctx.lineTo(x, y);
      }

      ctx.strokeStyle = "rgba(168, 85, 247, 0.8)";
      ctx.lineWidth = (6 + level * 4) * plate;
      ctx.shadowColor = "rgba(168, 85, 247, 0.75)";
      ctx.shadowBlur = (6 + level * 4) * plate;
      ctx.stroke();

      ctx.strokeStyle = "rgb(192, 132, 252)";
      ctx.lineWidth = 2.5 * plate;
      ctx.shadowColor = "rgba(255, 255, 255, 0.6)";
      ctx.shadowBlur = 3 * plate;
      ctx.stroke();

      ctx.shadowBlur = 0;
      break;
    }

    case 15: { // Eclipse (日蝕)
      const rays = 16;
      const r = Math.min(w, h) * 0.32;

      for (let i = 0; i < rays; i++) {
        const angle = (i / rays) * Math.PI * 2 + phase * 0.5;
        const noise = Math.sin(phase * 3 + i * 1.7) * 0.3 + 0.7;
        const rayLen = r * (1.2 + (level * 0.9 + 0.1) * noise * 0.8);
        const endX = cx + Math.cos(angle) * rayLen;
        const endY = cy + Math.sin(angle) * rayLen;

        const grad = ctx.createLinearGradient(cx, cy, endX, endY);
        grad.addColorStop(0, "rgba(251, 191, 36, 0.9)");
        grad.addColorStop(0.6, "rgba(245, 158, 11, 0.5)");
        grad.addColorStop(1, "rgba(217, 119, 6, 0)");

        ctx.strokeStyle = grad;
        ctx.lineWidth = (3 + level * 2) * plate;
        ctx.beginPath();
        ctx.moveTo(cx, cy);
        ctx.lineTo(endX, endY);
        ctx.stroke();
      }

      const haloR = r * (1.05 + level * 0.25) * 1.4;
      const haloGrad = ctx.createRadialGradient(cx, cy, r * 0.8, cx, cy, haloR);
      haloGrad.addColorStop(0, "rgb(254, 240, 138)");
      haloGrad.addColorStop(0.5, "rgb(245, 158, 11)");
      haloGrad.addColorStop(1, "rgba(180, 83, 9, 0)");

      ctx.fillStyle = haloGrad;
      ctx.beginPath();
      ctx.arc(cx, cy, haloR, 0, Math.PI * 2);
      ctx.fill();

      // Dark Disc
      ctx.fillStyle = "rgb(13, 14, 18)";
      ctx.strokeStyle = "rgba(254, 240, 138, 0.8)";
      ctx.lineWidth = 1.2 * plate;
      ctx.beginPath();
      ctx.arc(cx, cy, r, 0, Math.PI * 2);
      ctx.fill();
      ctx.stroke();
      break;
    }

    case 16: { // Smoke (煙霧)
      const blobs = 7;
      const baseRadius = Math.min(w, h) * (0.28 + level * 0.25);
      ctx.globalCompositeOperation = "screen";

      for (let i = 0; i < blobs; i++) {
        const angle = phase * (0.4 + i * 0.15) + (i * Math.PI * 2) / blobs;
        const drift = (12 * plate + level * 28 * plate) * (0.5 + 0.5 * Math.sin(phase * 0.8 + i));
        const bx = cx + Math.cos(angle) * drift;
        const by = cy + Math.sin(angle * 1.3) * (drift * 0.5) - level * 10 * plate;
        const radius = Math.max(1, baseRadius * (0.7 + 0.4 * Math.sin(phase + i * 1.7)));

        const alpha = 0.22 + level * 0.35;
        const grad = ctx.createRadialGradient(bx, by, 0, bx, by, radius);
        grad.addColorStop(0, `rgba(165, 180, 252, ${alpha})`);
        grad.addColorStop(0.45, `rgba(99, 102, 241, ${alpha * 0.65})`);
        grad.addColorStop(0.8, `rgba(79, 70, 229, ${alpha * 0.2})`);
        grad.addColorStop(1, "rgba(15, 23, 42, 0)");

        ctx.fillStyle = grad;
        ctx.beginPath();
        ctx.arc(bx, by, radius, 0, Math.PI * 2);
        ctx.fill();
      }
      ctx.globalCompositeOperation = "source-over";
      break;
    }

    case 17: { // HorizontalSmoke (橫煙)
      const layers = 4;
      ctx.globalCompositeOperation = "screen";

      for (let l = 0; l < layers; l++) {
        const amp = (6 * plate + level * 16 * plate) * (1 - l * 0.18);
        const freq = 0.03 + l * 0.01;
        const speed = phase * (0.8 + l * 0.3);

        ctx.beginPath();
        ctx.moveTo(0, h);
        for (let x = 0; x <= w; x += 4 * plate) {
          const wave = Math.sin((x * freq) / plate + speed) * Math.cos((x * 0.015) / plate - speed * 0.5);
          const y = cy + wave * amp + (l - 1.5) * 4 * plate;
          ctx.lineTo(x, y);
        }
        ctx.lineTo(w, h);
        ctx.closePath();

        const alpha = 0.25 + level * 0.35 - l * 0.04;
        const grad = ctx.createLinearGradient(0, cy - amp, 0, cy + amp + 10 * plate);
        grad.addColorStop(0, `rgba(192, 132, 252, ${alpha})`);
        grad.addColorStop(0.5, `rgba(129, 140, 248, ${alpha * 0.8})`);
        grad.addColorStop(1, "rgba(15, 23, 42, 0)");

        ctx.fillStyle = grad;
        ctx.fill();
      }
      ctx.globalCompositeOperation = "source-over";
      break;
    }

    case 18: { // OceanSwell (海浪)
      for (let i = 2; i >= 0; i--) {
        const baseH = h * (0.55 + i * 0.08);
        const amp = (4 * plate + level * 16 * plate) * (1 - i * 0.2);
        const speed = phase * (1.0 + i * 0.4);

        ctx.beginPath();
        ctx.moveTo(0, h);
        for (let x = 0; x <= w; x += 3 * plate) {
          const normX = x / w;
          const crest = Math.sin(normX * Math.PI * 3 + speed) * amp;
          const detail = Math.cos(normX * Math.PI * 7 - speed * 1.5) * (amp * 0.35);
          ctx.lineTo(x, baseH + crest + detail);
        }
        ctx.lineTo(w, h);
        ctx.closePath();

        const grad = ctx.createLinearGradient(0, baseH - amp, 0, h);
        if (i === 0) {
          grad.addColorStop(0, `rgba(56, 189, 248, ${0.7 + level * 0.3})`);
          grad.addColorStop(0.4, `rgba(14, 165, 233, ${0.4 + level * 0.4})`);
          grad.addColorStop(1, "rgba(3, 105, 161, 0.1)");
        } else if (i === 1) {
          grad.addColorStop(0, `rgba(129, 140, 248, ${0.5 + level * 0.3})`);
          grad.addColorStop(1, "rgba(30, 27, 75, 0.2)");
        } else {
          grad.addColorStop(0, `rgba(99, 102, 241, ${0.35 + level * 0.25})`);
          grad.addColorStop(1, "rgba(15, 23, 42, 0.3)");
        }

        ctx.fillStyle = grad;
        ctx.fill();
      }
      break;
    }

    case 19: { // SilkStream (絲綢氣流)
      ctx.globalCompositeOperation = "screen";
      for (let r = 0; r < 3; r++) {
        const offsetPhase = phase + r * 1.2;
        const amp = 6 * plate + level * 14 * plate;

        ctx.beginPath();
        for (let x = 0; x <= w; x += 4 * plate) {
          const t = x / w;
          const y = cy + Math.sin(t * 5 + offsetPhase) * amp + Math.cos(t * 3 - offsetPhase * 0.7) * (amp * 0.5);
          if (x === 0) ctx.moveTo(x, y);
          else ctx.lineTo(x, y);
        }
        for (let x = w; x >= 0; x -= 4 * plate) {
          const t = x / w;
          const y = cy + Math.sin(t * 5 + offsetPhase + 0.4) * (amp * 1.1) + Math.cos(t * 3 - offsetPhase * 0.7) * (amp * 0.4) + (8 * plate + level * 8 * plate);
          ctx.lineTo(x, y);
        }
        ctx.closePath();

        const alpha = 0.25 + level * 0.35;
        const grad = ctx.createLinearGradient(0, 0, w, h);
        if (r === 0) {
          grad.addColorStop(0, `rgba(236, 72, 153, ${alpha})`);
          grad.addColorStop(1, `rgba(139, 92, 246, ${alpha})`);
        } else if (r === 1) {
          grad.addColorStop(0, `rgba(99, 102, 241, ${alpha})`);
          grad.addColorStop(1, `rgba(45, 212, 191, ${alpha})`);
        } else {
          grad.addColorStop(0, `rgba(168, 85, 247, ${alpha * 0.8})`);
          grad.addColorStop(1, `rgba(244, 63, 94, ${alpha * 0.8})`);
        }

        ctx.fillStyle = grad;
        ctx.fill();
      }
      ctx.globalCompositeOperation = "source-over";
      break;
    }

    case 20: { // AuroraMist (極光霧)
      ctx.globalCompositeOperation = "screen";
      for (let b = 0; b < 4; b++) {
        const p = phase * (0.6 + b * 0.2);
        const amp = 8 * plate + level * 18 * plate;

        ctx.beginPath();
        ctx.moveTo(0, 0);
        for (let x = 0; x <= w; x += 4 * plate) {
          const normX = x / w;
          const y = h * 0.4 + Math.sin(normX * 4 + p) * amp + Math.sin(normX * 8 - p * 1.2) * (amp * 0.4) + b * 4 * plate;
          ctx.lineTo(x, y);
        }
        ctx.lineTo(w, h);
        ctx.lineTo(0, h);
        ctx.closePath();

        const alpha = 0.2 + level * 0.35;
        const grad = ctx.createLinearGradient(0, 0, 0, h);
        if (b % 2 === 0) {
          grad.addColorStop(0, `rgba(52, 211, 153, ${alpha})`);
          grad.addColorStop(0.5, `rgba(99, 102, 241, ${alpha * 0.7})`);
          grad.addColorStop(1, "rgba(15, 23, 42, 0)");
        } else {
          grad.addColorStop(0, `rgba(167, 139, 250, ${alpha})`);
          grad.addColorStop(0.6, `rgba(56, 189, 248, ${alpha * 0.6})`);
          grad.addColorStop(1, "rgba(15, 23, 42, 0)");
        }

        ctx.fillStyle = grad;
        ctx.fill();
      }
      ctx.globalCompositeOperation = "source-over";
      break;
    }

    case 21: { // InkBloom (墨滴擴散)
      const drops = 5;
      ctx.globalCompositeOperation = "screen";

      for (let d = 0; d < drops; d++) {
        const seed = d * 17 + 3;
        const pseudoRand = Math.abs(Math.sin(seed) * 10000) % 1;
        const bx = w * (0.2 + 0.6 * pseudoRand);
        const by = cy + ((Math.abs(Math.sin(seed + 1) * 10000) % 1) - 0.5) * 12 * plate;
        const pulse = Math.sin(phase * 0.8 + d * 1.5) * 0.5 + 0.5;
        const radius = Math.max(1, (12 * plate + level * 26 * plate) * (0.6 + 0.4 * pulse));

        const alpha = 0.3 + level * 0.4;
        const grad = ctx.createRadialGradient(bx, by, 0, bx, by, radius);
        if (d % 3 === 0) {
          grad.addColorStop(0, `rgba(129, 140, 248, ${alpha})`);
          grad.addColorStop(0.5, `rgba(79, 70, 229, ${alpha * 0.5})`);
        } else if (d % 3 === 1) {
          grad.addColorStop(0, `rgba(192, 132, 252, ${alpha})`);
          grad.addColorStop(0.5, `rgba(147, 51, 234, ${alpha * 0.5})`);
        } else {
          grad.addColorStop(0, `rgba(56, 189, 248, ${alpha})`);
          grad.addColorStop(0.5, `rgba(2, 132, 199, ${alpha * 0.5})`);
        }
        grad.addColorStop(1, "rgba(15, 23, 42, 0)");

        ctx.fillStyle = grad;
        ctx.beginPath();
        ctx.arc(bx, by, radius, 0, Math.PI * 2);
        ctx.fill();
      }
      ctx.globalCompositeOperation = "source-over";
      break;
    }

    default:
      break;
  }
}

/**
 * Reusable Mini HUD Canvas Component for Gallery & Main Stage
 */
function MiniHUDCanvas({
  hudId,
  width = 156,
  height = 52,
  isRecording = true,
  className = "",
}: {
  hudId: number;
  width?: number;
  height?: number;
  isRecording?: boolean;
  className?: string;
}) {
  const canvasRef = useRef<HTMLCanvasElement | null>(null);

  useEffect(() => {
    let animId: number;
    let phase = 0;

    const mediaQuery = window.matchMedia("(prefers-reduced-motion: reduce)");

    const drawFrame = (currentPhase: number) => {
      const baseLevel = isRecording ? 0.65 : 0.08;
      const level = Math.max(
        0.05,
        Math.min(1.0, baseLevel + Math.sin(currentPhase * 1.8) * 0.25 + Math.cos(currentPhase * 2.4) * 0.1)
      );

      const canvas = canvasRef.current;
      if (canvas) {
        const ctx = canvas.getContext("2d");
        if (ctx) {
          drawHUD(ctx, hudId, canvas.width, canvas.height, currentPhase, level);
        }
      }
    };

    const render = () => {
      phase += 0.04;
      drawFrame(phase);
      animId = requestAnimationFrame(render);
    };

    const startOrStop = () => {
      if (animId) {
        cancelAnimationFrame(animId);
      }
      if (mediaQuery.matches) {
        // Draw one stable representative frame without starting recursive loop
        drawFrame(1.0);
      } else {
        animId = requestAnimationFrame(render);
      }
    };

    startOrStop();

    const handleQueryChange = () => {
      startOrStop();
    };

    if (mediaQuery.addEventListener) {
      mediaQuery.addEventListener("change", handleQueryChange);
    } else {
      mediaQuery.addListener(handleQueryChange);
    }

    return () => {
      if (animId) {
        cancelAnimationFrame(animId);
      }
      if (mediaQuery.removeEventListener) {
        mediaQuery.removeEventListener("change", handleQueryChange);
      } else {
        mediaQuery.removeListener(handleQueryChange);
      }
    };
  }, [hudId, isRecording]);

  return (
    <canvas
      ref={canvasRef}
      width={width}
      height={height}
      className={`rounded-full ${className}`}
    />
  );
}

export default function NexVoiceShowcase() {
  const [selectedTheme, setSelectedTheme] = useState(THEMES[0]);
  const [selectedHud, setSelectedHud] = useState(HUDS[0]);
  const [selectedChrome, setSelectedChrome] = useState(CHROMES[0]);
  const [selectedSubtitle, setSelectedSubtitle] = useState(SUBTITLE_STYLES[0]);
  const [appState, setAppState] = useState<"ready" | "recording" | "processing" | "done">("recording");
  const [elapsedTime, setElapsedTime] = useState(1.8);
  const [isCompareMode, setIsCompareMode] = useState(false);
  const [starCount, setStarCount] = useState<number | null>(null);
  const compareList = [1, 8, 13]; // GlassBars, Siri, Mercury

  useEffect(() => {
    fetch("https://api.github.com/repos/awe7893625/nexvoice")
      .then((res) => res.json())
      .then((data) => {
        if (typeof data.stargazers_count === "number") {
          setStarCount(data.stargazers_count);
        }
      })
      .catch(() => {
        // Fallback silently if fetch fails
      });
  }, []);

  // Elapsed time counter simulation
  useEffect(() => {
    let timer: NodeJS.Timeout;
    if (appState === "recording") {
      timer = setInterval(() => {
        setElapsedTime((prev) => parseFloat((prev + 0.1).toFixed(1)));
      }, 100);
    }
    return () => clearInterval(timer);
  }, [appState]);

  // Keyboard navigation for HUD selection
  const handleKeyDown = (e: React.KeyboardEvent) => {
    if (e.key === "ArrowRight" || e.key === "ArrowDown") {
      const idx = (HUDS.findIndex((h) => h.id === selectedHud.id) + 1) % HUDS.length;
      setSelectedHud(HUDS[idx]);
    } else if (e.key === "ArrowLeft" || e.key === "ArrowUp") {
      const idx = (HUDS.findIndex((h) => h.id === selectedHud.id) - 1 + HUDS.length) % HUDS.length;
      setSelectedHud(HUDS[idx]);
    }
  };

  return (
    <main className="min-h-screen bg-[#07090e] text-slate-100 selection:bg-cyan-500/30 selection:text-cyan-200 overflow-x-hidden">
      {/* Background Decor */}
      <div className="fixed inset-0 pointer-events-none overflow-hidden z-0">
        <div className="absolute -top-40 -left-40 w-96 h-96 bg-cyan-600/15 rounded-full blur-[120px]" />
        <div className="absolute top-1/3 -right-40 w-96 h-96 bg-purple-600/15 rounded-full blur-[120px]" />
        <div className="absolute -bottom-40 left-1/3 w-96 h-96 bg-blue-600/10 rounded-full blur-[140px]" />
      </div>

      {/* Navigation Header */}
      <header className="sticky top-0 z-50 glass-panel border-b border-white/10 px-3 sm:px-4 md:px-8 py-2.5 sm:py-3.5 flex items-center justify-between">
        <div className="flex items-center space-x-2 sm:space-x-3 min-w-0">
          <div className="w-8 h-8 sm:w-9 sm:h-9 rounded-xl bg-gradient-to-tr from-cyan-500 to-purple-600 flex items-center justify-center font-bold text-white shadow-lg shadow-cyan-500/20 shrink-0">
            N
          </div>
          <div className="min-w-0">
            <h1 className="font-bold text-base sm:text-lg tracking-wide text-white flex items-center gap-1.5 sm:gap-2">
              NexVoice
              <span className="hidden sm:inline-block text-[10px] font-mono bg-cyan-500/20 border border-cyan-500/40 text-cyan-300 px-2 py-0.5 rounded-full">
                macOS Native App
              </span>
            </h1>
            <p className="text-[11px] sm:text-xs text-slate-400 truncate">Apple Silicon 本地極速聽寫 · 零費用隱私</p>
          </div>
        </div>

        <nav aria-label="Main Navigation" className="hidden lg:flex items-center space-x-6 text-xs font-medium text-slate-300">
          <a href="#hero" className="hover:text-cyan-400 transition-colors">產品體驗</a>
          <a href="#hud-gallery" className="hover:text-cyan-400 transition-colors">21 款 HUD 藝廊</a>
          <a href="#storytelling" className="hover:text-cyan-400 transition-colors">核心技術流程</a>
          <a href="#architecture" className="hover:text-cyan-400 transition-colors">本機/雲端架構</a>
          <a href="#ai-setup" className="hover:text-cyan-400 transition-colors">AI 3步驟配置</a>
          <a href="#api" className="hover:text-cyan-400 transition-colors">REST API 整合</a>
          <a href="#faq" className="hover:text-cyan-400 transition-colors">FAQ</a>
        </nav>

        <div className="flex items-center space-x-1.5 sm:space-x-3 shrink-0">
          <a
            href="https://github.com/awe7893625/nexvoice"
            target="_blank"
            rel="noopener noreferrer"
            className="bg-gradient-to-r from-amber-500 to-amber-600 hover:from-amber-400 hover:to-amber-500 text-slate-950 font-bold px-3 sm:px-4 py-1.5 sm:py-2 rounded-lg shadow-lg shadow-amber-500/20 transition-all hover:scale-105 flex items-center space-x-1.5 text-xs"
          >
            <svg className="w-4 h-4 fill-current" viewBox="0 0 16 16" aria-hidden="true">
              <path d="M8 .25a.75.75 0 0 1 .673.418l1.882 3.815 4.21.612a.75.75 0 0 1 .416 1.279l-3.046 2.97.719 4.192a.75.75 0 0 1-1.088.791L8 12.347l-3.766 1.98a.75.75 0 0 1-1.088-.79l.72-4.194L.818 6.374a.75.75 0 0 1 .416-1.28l4.21-.611L7.327.668A.75.75 0 0 1 8 .25z" />
            </svg>
            <span className="hidden sm:inline">Star on GitHub</span>
            <span className="sm:hidden">Star</span>
            {starCount !== null && (
              <span className="hidden min-[380px]:inline-block bg-slate-950/30 text-amber-200 text-[10px] px-1.5 py-0.5 rounded-full font-mono">
                {starCount}
              </span>
            )}
          </a>
          <a
            href="https://github.com/awe7893625/nexvoice/archive/refs/heads/main.zip"
            download
            className="hidden sm:flex glass-card px-2.5 sm:px-3.5 py-1.5 sm:py-2 rounded-lg text-xs font-semibold text-slate-200 hover:text-white items-center space-x-1.5 border border-white/10"
          >
            <span>下載原始碼 ZIP</span>
          </a>
          <a
            href="#install"
            className="bg-gradient-to-r from-cyan-500 to-blue-600 hover:from-cyan-400 hover:to-blue-500 text-white font-semibold text-xs px-2.5 sm:px-4 py-1.5 sm:py-2 rounded-lg shadow-lg shadow-cyan-500/20 transition-all hover:scale-105"
          >
            <span className="hidden sm:inline">安裝指南</span>
            <span className="sm:hidden">指南</span>
          </a>
        </div>
      </header>

      {/* Hero Section with Realistic Compact macOS HUD & App Window Mockup */}
      <section className="relative pt-8 sm:pt-12 pb-16 px-4 md:px-8 max-w-6xl mx-auto text-center" id="hero">
        <div className="inline-flex items-center space-x-2 glass-panel border border-cyan-500/30 text-cyan-300 text-xs px-4 py-1.5 rounded-full mb-6 shadow-lg shadow-cyan-500/10 max-w-full">
          <span className="w-2 h-2 rounded-full bg-cyan-400 animate-ping shrink-0" />
          <span className="font-medium truncate sm:whitespace-normal">100% 獨立 SwiftUI macOS 桌面應用，無障礙輔助權限原生整合</span>
        </div>

        <h2 className="text-3xl sm:text-5xl md:text-6xl font-extrabold tracking-tight mb-4 sm:mb-6 text-gradient leading-tight">
          熱鍵一按即聽 · 放開立貼
        </h2>

        <p className="max-w-3xl mx-auto text-slate-300 text-sm sm:text-lg mb-8 sm:mb-10 leading-relaxed font-normal">
          專為 Apple Silicon Mac 打造。預設 100% 本地運算 MLX Whisper 模型，無須 API 金鑰，零月費，音訊與語音文本全數保留於本機。
        </p>

        <div className="flex flex-wrap items-center justify-center gap-3 sm:gap-4 mb-10 sm:mb-14" id="install">
          <a
            href="https://github.com/awe7893625/nexvoice/archive/refs/heads/main.zip"
            download
            className="bg-cyan-500 hover:bg-cyan-400 text-slate-950 font-bold px-5 sm:px-7 py-3 sm:py-3.5 rounded-xl shadow-xl shadow-cyan-500/25 transition-all hover:scale-105 text-sm w-full sm:w-auto"
          >
            下載乾淨原始碼 ZIP
          </a>
          <a
            href="#hud-gallery"
            className="glass-panel border border-white/10 hover:border-cyan-500/40 text-slate-200 font-semibold px-5 sm:px-6 py-3 sm:py-3.5 rounded-xl transition-all text-sm w-full sm:w-auto"
          >
            探索 21 款真實 HUD 設計
          </a>
        </div>

        {/* First Viewport: High Fidelity macOS Window & Floating Compact HUD Mockup */}
        <div className="relative max-w-4xl mx-auto">
          {/* Main Simulated App Window */}
          <div className={`glass-panel rounded-2xl border transition-colors duration-300 shadow-2xl overflow-hidden text-left ${selectedTheme.bg} ${selectedTheme.border}`}>
            {/* macOS Window Bar */}
            <div className="px-4 py-3 border-b border-white/10 flex items-center justify-between bg-black/30 backdrop-blur-md">
              <div className="flex items-center space-x-2">
                <span className="w-3 h-3 rounded-full bg-red-500/90 inline-block shadow-sm" />
                <span className="w-3 h-3 rounded-full bg-yellow-500/90 inline-block shadow-sm" />
                <span className="w-3 h-3 rounded-full bg-green-500/90 inline-block shadow-sm" />
                <span className="text-xs font-mono text-slate-400 ml-2 font-medium truncate max-w-[140px] sm:max-w-none">NexVoice.app — {selectedTheme.name}</span>
              </div>
              <div className="flex items-center space-x-2">
                <span className="text-[10px] sm:text-[11px] font-mono bg-cyan-500/20 text-cyan-300 border border-cyan-500/40 px-2 py-0.5 rounded-md flex items-center gap-1">
                  <span className="w-1.5 h-1.5 rounded-full bg-cyan-400 animate-pulse" />
                  <span className="hidden sm:inline">Local MLX Whisper Active</span>
                  <span className="sm:hidden">MLX Active</span>
                </span>
              </div>
            </div>

            {/* Window Content Controls */}
            <div className="p-4 sm:p-6 md:p-8 space-y-4 sm:space-y-6 pb-28 sm:pb-8">
              {/* State & Control Switcher Bar */}
              <div className="flex flex-col sm:flex-row sm:items-center justify-between gap-3 sm:gap-4 p-3.5 sm:p-4 rounded-xl bg-white/5 border border-white/10">
                <div className="flex flex-col gap-2">
                  <span className="text-xs font-semibold text-slate-300">錄音狀態:</span>
                  <div className="grid grid-cols-2 sm:flex sm:items-center gap-1.5 sm:space-x-2">
                    {(["ready", "recording", "processing", "done"] as const).map((st) => (
                      <button
                        key={st}
                        onClick={() => {
                          setAppState(st);
                          if (st === "recording") setElapsedTime(0.1);
                        }}
                        className={`px-2.5 py-1.5 sm:py-1 rounded-lg text-xs font-medium transition-all text-center ${
                          appState === st
                            ? "bg-cyan-500 text-slate-950 font-bold shadow-md shadow-cyan-500/20"
                            : "bg-slate-800/60 text-slate-400 hover:text-white"
                        }`}
                      >
                        <span className="sm:hidden">
                          {st === "ready" && "就緒"}
                          {st === "recording" && "錄音中"}
                          {st === "processing" && "轉錄中"}
                          {st === "done" && "完成"}
                        </span>
                        <span className="hidden sm:inline">
                          {st === "ready" && "就緒 (Ready)"}
                          {st === "recording" && "錄音中 (Recording)"}
                          {st === "processing" && "轉錄中 (Processing)"}
                          {st === "done" && "完成 (Done)"}
                        </span>
                      </button>
                    ))}
                  </div>
                </div>

                {/* Theme Selector */}
                <div className="flex flex-col sm:flex-row sm:items-center gap-2 pt-2 sm:pt-0 border-t border-white/5 sm:border-t-0">
                  <span className="text-xs font-semibold text-slate-300">App 主題:</span>
                  <div className="flex items-center gap-1.5">
                    {THEMES.map((th) => (
                      <button
                        key={th.id}
                        onClick={() => setSelectedTheme(th)}
                        className={`flex-1 sm:flex-none px-2.5 py-1 rounded-md text-xs font-medium border transition-all text-center ${
                          selectedTheme.id === th.id
                            ? "border-cyan-400 bg-cyan-500/20 text-cyan-200"
                            : "border-white/10 bg-slate-900/40 text-slate-400 hover:text-slate-200"
                        }`}
                      >
                        {th.name.split(" ")[0]}
                      </button>
                    ))}
                  </div>
                </div>
              </div>

              {/* Subtitle Style Selector */}
              <div className="flex flex-wrap items-center gap-2">
                <span className="text-xs font-semibold text-slate-300 w-full sm:w-auto mb-1 sm:mb-0">字幕呈現風格 (SubtitleStyle):</span>
                <div className="flex flex-wrap items-center gap-1.5 w-full sm:w-auto">
                  {SUBTITLE_STYLES.map((st) => (
                    <button
                      key={st.id}
                      onClick={() => setSelectedSubtitle(st)}
                      className={`px-2.5 sm:px-3 py-1 rounded-lg text-xs font-medium border transition-all ${
                        selectedSubtitle.id === st.id
                          ? "border-purple-400 bg-purple-500/20 text-purple-200 shadow-sm"
                          : "border-white/10 bg-slate-900/30 text-slate-400 hover:text-slate-200"
                      }`}
                    >
                      {st.name}
                    </button>
                  ))}
                </div>
              </div>

              {/* Simulated Desktop Editor Area */}
              <div className="relative rounded-xl border border-white/10 bg-slate-950/60 p-4 sm:p-5 min-h-[140px] sm:min-h-[160px] font-mono text-xs sm:text-sm text-slate-200">
                <div className="text-[11px] sm:text-xs text-slate-500 mb-2 border-b border-white/5 pb-1 flex justify-between gap-2">
                  <span className="truncate">Document.txt — Active Focus Window</span>
                  <span className="shrink-0">Hotkey: Fn / Right-Cmd</span>
                </div>
                <p className="leading-relaxed">
                  Today, I am testing the new <span className="text-cyan-400 underline decoration-cyan-500/40">NexVoice macOS Native App</span>.
                  {appState === "done" && (
                    <span className="text-emerald-300 bg-emerald-500/10 px-1 py-0.5 rounded border border-emerald-500/30 ml-1">
                      {" "}{selectedSubtitle.text}
                    </span>
                  )}
                  {appState === "recording" && (
                    <span className="inline-block w-2 h-4 bg-cyan-400 animate-pulse ml-1 align-middle" />
                  )}
                </p>
              </div>
            </div>
          </div>

          {/* Floating Compact macOS HUD Overlaid */}
          <div className="absolute top-1/2 left-1/2 -translate-x-1/2 -translate-y-1/2 z-20 pointer-events-none w-full max-w-[340px] sm:max-w-sm flex flex-col items-center px-2">
            {/* Live Subtitle Bubble Floating Above Capsule */}
            <div className="mb-3 transform hover:scale-105 transition-transform pointer-events-auto w-full flex justify-center">
              <div className="bg-slate-950/90 backdrop-blur-xl border border-white/20 px-4 sm:px-5 py-2 sm:py-2.5 rounded-full shadow-2xl text-center max-w-[300px] sm:max-w-sm">
                <p className="text-xs sm:text-sm font-medium text-white tracking-wide truncate">
                  {appState === "ready" && "按住熱鍵開始聽寫..."}
                  {appState === "recording" && selectedSubtitle.text}
                  {appState === "processing" && "MLX Whisper 本地聲學推論中..."}
                  {appState === "done" && "轉錄成功！已自動貼上至文字框"}
                </p>
              </div>
            </div>

            {/* Compact HUD Capsule (plated vs naked) */}
            <div className="pointer-events-auto flex flex-col items-center">
              {selectedChrome.id === "naked" ? (
                /* Naked Mode (2x Siri Floating) */
                <div className="p-4 flex flex-col items-center justify-center">
                  {appState === "processing" ? (
                    <span className="text-xs font-semibold text-white tracking-widest animate-pulse drop-shadow-md">
                      Thinking…
                    </span>
                  ) : (
                    <div className="scale-150 drop-shadow-2xl">
                      <MiniHUDCanvas hudId={selectedHud.id} isRecording={appState === "recording"} />
                    </div>
                  )}
                </div>
              ) : (
                /* Plated Capsule Mode with Selected Chrome */
                <div
                  className={`relative px-5 sm:px-6 py-2 sm:py-2.5 rounded-full flex items-center justify-center space-x-3 transition-all duration-300 bg-gradient-to-b from-slate-900/95 to-slate-950/95 shadow-2xl border ${
                    selectedChrome.id === "hairline"
                      ? "border-white/30"
                      : selectedChrome.id === "glowEdge"
                      ? "border-cyan-400/80 shadow-[0_0_20px_rgba(56,189,248,0.4)]"
                      : selectedChrome.id === "breathingRing"
                      ? "border-purple-400/50 shadow-[0_0_15px_rgba(168,85,247,0.3)] animate-pulse"
                      : selectedChrome.id === "aura"
                      ? "border-cyan-400/60 shadow-[0_0_30px_rgba(56,189,248,0.5)]"
                      : selectedChrome.id === "emboss"
                      ? "border-amber-900/40 shadow-inner bg-[#1c1917]"
                      : "border-white/10"
                  }`}
                >
                  {appState === "processing" ? (
                    <span className="text-xs font-semibold text-white tracking-wider animate-pulse px-4 py-1">
                      Thinking…
                    </span>
                  ) : (
                    <div className="flex items-center space-x-3">
                      <MiniHUDCanvas hudId={selectedHud.id} isRecording={appState === "recording"} />
                      <span className="text-[11px] font-mono text-cyan-300 font-bold bg-cyan-950/60 px-2 py-0.5 rounded-md border border-cyan-500/30">
                        {appState === "recording" ? `${elapsedTime.toFixed(1)}s` : "0.0s"}
                      </span>
                    </div>
                  )}
                </div>
              )}
            </div>
          </div>
        </div>
      </section>

      {/* Section 2: Visual 21-Card HUD Gallery & Compare Mode */}
      <section id="hud-gallery" className="py-16 px-4 md:px-8 max-w-6xl mx-auto border-t border-white/10">
        <div className="flex flex-col md:flex-row md:items-end justify-between mb-10 gap-4">
          <div>
            <div className="inline-flex items-center gap-2 text-xs font-mono text-cyan-400 mb-2 uppercase tracking-wider">
              <span>Visual Truth Roster</span>
              <span>•</span>
              <span>21 Authentic HUD Renderers</span>
            </div>
            <h3 className="text-3xl md:text-4xl font-bold text-white">21 款原生 macOS HUD 動態藝廊</h3>
            <p className="text-slate-400 text-sm mt-1">
              實時對齊 macOS Swift 繪圖引擎 (HUDDesignPack.swift)。點選任一卡片即可同步替換上方大舞台。
            </p>
          </div>

          <div className="flex items-center space-x-3">
            <button
              onClick={() => setIsCompareMode(!isCompareMode)}
              className={`px-4 py-2 rounded-xl text-xs font-bold border transition-all flex items-center gap-2 ${
                isCompareMode
                  ? "bg-cyan-500 text-slate-950 border-cyan-400 shadow-lg shadow-cyan-500/20"
                  : "bg-white/5 border-white/10 text-slate-300 hover:bg-white/10"
              }`}
            >
              <span>{isCompareMode ? "✓ 關閉 Compare Mode" : "⚡ 開啟 Compare Mode (3款並列)"}</span>
            </button>
          </div>
        </div>

        {/* Chrome Selector Tabs */}
        <div className="flex flex-wrap items-center gap-2 mb-8 p-3 rounded-2xl bg-slate-900/60 border border-white/10">
          <span className="text-xs font-semibold text-slate-400 mr-2">邊框渲染 (HUDChrome):</span>
          {CHROMES.map((ch) => (
            <button
              key={ch.id}
              onClick={() => setSelectedChrome(ch)}
              className={`px-3 py-1.5 rounded-lg text-xs font-medium border transition-all ${
                selectedChrome.id === ch.id
                  ? "border-cyan-400 bg-cyan-500/20 text-cyan-200 shadow-sm"
                  : "border-white/5 bg-white/5 text-slate-400 hover:text-slate-200"
              }`}
            >
              {ch.name}
            </button>
          ))}
        </div>

        {/* Compare Mode 3 HUDs Panel */}
        {isCompareMode && (
          <div className="mb-12 glass-panel border border-cyan-500/40 rounded-2xl p-6 shadow-2xl bg-cyan-950/20">
            <div className="flex items-center justify-between mb-6 border-b border-cyan-500/30 pb-3">
              <h4 className="text-sm font-bold text-cyan-300 flex items-center gap-2">
                <span>⚡ 3 Representative HUD Visual Comparison Mode</span>
              </h4>
              <span className="text-xs text-slate-400 font-mono">Simultaneous Multi-Canvas Render</span>
            </div>

            <div className="grid md:grid-cols-3 gap-6">
              {compareList.map((id) => {
                const hud = HUDS.find((h) => h.id === id) || HUDS[0];
                return (
                  <div
                    key={id}
                    className="glass-card p-5 rounded-xl border border-white/10 flex flex-col items-center text-center bg-slate-900/80"
                  >
                    <span className="text-[10px] font-mono text-cyan-400 mb-2">HUD #{hud.id} · {hud.category}</span>
                    <h5 className="font-bold text-sm text-white mb-3">{hud.name} ({hud.englishName})</h5>
                    
                    <div className="w-full h-24 bg-slate-950/80 rounded-lg flex items-center justify-center p-3 mb-3 border border-white/5">
                      <MiniHUDCanvas hudId={hud.id} width={160} height={56} className="shadow-lg" />
                    </div>

                    <p className="text-xs text-slate-400 leading-relaxed mb-4">{hud.desc}</p>
                    
                    <button
                      onClick={() => setSelectedHud(hud)}
                      className="w-full py-1.5 rounded-lg text-xs font-semibold bg-cyan-500/20 hover:bg-cyan-500/30 text-cyan-300 border border-cyan-500/40 transition-colors"
                    >
                      設為主舞台展示
                    </button>
                  </div>
                );
              })}
            </div>
          </div>
        )}

        {/* 21 Visual Cards Gallery Grid */}
        <div
          tabIndex={0}
          onKeyDown={handleKeyDown}
          className="grid grid-cols-1 sm:grid-cols-2 lg:grid-cols-3 xl:grid-cols-4 gap-4 focus:outline-none focus:ring-2 focus:ring-cyan-500/50 p-1 rounded-2xl"
        >
          {HUDS.map((hud) => {
            const isSelected = selectedHud.id === hud.id;
            return (
              <div
                key={hud.id}
                onClick={() => setSelectedHud(hud)}
                className={`glass-card p-4 rounded-xl border cursor-pointer transition-all flex flex-col justify-between group ${
                  isSelected
                    ? "border-cyan-400 bg-cyan-500/15 text-white shadow-xl shadow-cyan-500/10 ring-1 ring-cyan-400/50"
                    : "border-white/10 bg-slate-900/40 text-slate-300 hover:border-cyan-500/30 hover:bg-slate-800/60"
                }`}
              >
                <div>
                  <div className="flex items-center justify-between mb-2">
                    <span className="text-[10px] font-mono text-cyan-400 font-bold bg-cyan-950/60 px-2 py-0.5 rounded border border-cyan-500/30">
                      HUD #{hud.id}
                    </span>
                    <span className="text-[10px] text-slate-400 font-medium">{hud.category}</span>
                  </div>

                  <h4 className="font-bold text-sm text-white mb-1 group-hover:text-cyan-300 transition-colors">
                    {hud.name} <span className="text-xs font-normal text-slate-400">({hud.englishName})</span>
                  </h4>

                  {/* Animated Canvas Mini Preview */}
                  <div className="my-3 py-3 px-2 bg-slate-950/90 rounded-lg flex items-center justify-center border border-white/5 shadow-inner">
                    <MiniHUDCanvas hudId={hud.id} width={140} height={44} />
                  </div>

                  <p className="text-xs text-slate-400 leading-relaxed font-sans">{hud.desc}</p>
                </div>

                <div className="mt-4 pt-2 border-t border-white/5 flex items-center justify-between text-[11px]">
                  <span className={isSelected ? "text-cyan-300 font-semibold" : "text-slate-500"}>
                    {isSelected ? "● 目前主舞台款式" : "點擊載入"}
                  </span>
                  <span className="text-slate-500 group-hover:text-slate-300">Swift Canvas2D →</span>
                </div>
              </div>
            );
          })}
        </div>
      </section>

      {/* Section 3: Product Storytelling (Hotkey, Privacy, AI Auto-Config, Native App) */}
      <section id="storytelling" className="py-16 px-4 md:px-8 max-w-6xl mx-auto border-t border-white/10">
        <div className="text-center mb-12">
          <h3 className="text-3xl md:text-4xl font-bold text-white mb-3">獨立原生 macOS 應用核心特徵</h3>
          <p className="text-slate-400 text-sm max-w-2xl mx-auto">
            NexVoice 為完整 Swift/SwiftUI 原生寫成，提供極致流暢的快捷鍵體驗與本機隱私保障。
          </p>
        </div>

        <div className="grid md:grid-cols-2 lg:grid-cols-4 gap-6">
          {/* Card 1: Hotkey Flow */}
          <div className="glass-card p-6 rounded-2xl border border-white/10 flex flex-col justify-between">
            <div>
              <div className="w-10 h-10 rounded-xl bg-cyan-500/20 text-cyan-300 border border-cyan-500/40 flex items-center justify-center font-bold text-lg mb-4">
                ⌘
              </div>
              <h4 className="font-bold text-base text-white mb-2">熱鍵錄音 · 放開即貼</h4>
              <p className="text-xs text-slate-300 leading-relaxed">
                按住 Fn 或 右-Command 單鍵即刻聽寫，鬆開按鍵自動在目前焦點游標處精準貼上文本。
              </p>
            </div>
            <div className="mt-4 pt-3 border-t border-white/5 text-[11px] font-mono text-cyan-400">
              Hotkey Profile → Paste
            </div>
          </div>

          {/* Card 2: Local Privacy */}
          <div className="glass-card p-6 rounded-2xl border border-white/10 flex flex-col justify-between">
            <div>
              <div className="w-10 h-10 rounded-xl bg-emerald-500/20 text-emerald-300 border border-emerald-500/40 flex items-center justify-center font-bold text-lg mb-4">
                🔒
              </div>
              <h4 className="font-bold text-base text-white mb-2">本機優先 零費用隱私</h4>
              <p className="text-xs text-slate-300 leading-relaxed">
                預設 100% 離線執行 Apple Silicon MLX Whisper 模型，音訊檔不離開您的 Mac 記憶體。
              </p>
            </div>
            <div className="mt-4 pt-3 border-t border-white/5 text-[11px] font-mono text-emerald-400">
              100% Zero-Cost Local MLX
            </div>
          </div>

          {/* Card 3: AI Auto Config */}
          <div className="glass-card p-6 rounded-2xl border border-white/10 flex flex-col justify-between">
            <div>
              <div className="w-10 h-10 rounded-xl bg-purple-500/20 text-purple-300 border border-purple-500/40 flex items-center justify-center font-bold text-lg mb-4">
                🤖
              </div>
              <h4 className="font-bold text-base text-white mb-2">AI Agent 3步驟自動配置</h4>
              <p className="text-xs text-slate-300 leading-relaxed">
                內建 CLI / REST 自動化介面，讓 AI Agent 輕鬆完成環境探測、Doctor 檢查與 Schema 驗證。
              </p>
            </div>
            <div className="mt-4 pt-3 border-t border-white/5 text-[11px] font-mono text-purple-400">
              server/agent_cli.py
            </div>
          </div>

          {/* Card 4: Opt-in Gateway API */}
          <div className="glass-card p-6 rounded-2xl border border-white/10 flex flex-col justify-between">
            <div>
              <div className="w-10 h-10 rounded-xl bg-blue-500/20 text-blue-300 border border-blue-500/40 flex items-center justify-center font-bold text-lg mb-4">
                🌐
              </div>
              <h4 className="font-bold text-base text-white mb-2">Opt-in Cloud Gateway</h4>
              <p className="text-xs text-slate-300 leading-relaxed">
                支援可選 Gateway 雲端轉錄 (Gemini STT) 與 Groq / NIM 潤飾，提供 OpenAI 相容 API 端點。
              </p>
            </div>
            <div className="mt-4 pt-3 border-t border-white/5 text-[11px] font-mono text-blue-400">
              OpenAI Subset Compatible
            </div>
          </div>
        </div>
      </section>

      {/* Section 4: Architecture & Privacy Details */}
      <section id="architecture" className="py-16 px-4 md:px-8 max-w-6xl mx-auto border-t border-white/10">
        <div className="grid md:grid-cols-2 gap-8 items-center">
          <div>
            <h3 className="text-3xl font-bold text-white mb-4">Local-First 到 Opt-in Cloud 安全架構</h3>
            <p className="text-slate-300 text-sm leading-relaxed mb-6">
              NexVoice 設計核心為隱私保護與零成本運算。預設所有音訊均直接在 Apple Silicon 晶片上透過 MLX Whisper 轉錄。當使用者開啟 Gateway 雲端模式時，STT 轉錄專用 Gemini，可選文本潤飾支援 Groq、NIM 或 Gemini；App 端則提供明確的 Groq 與 Gemini 整合（其中 Groq 使用 OpenAI 相容 API），Gateway 亦提供對外 OpenAI 相容子集 API。
            </p>
            <ul className="space-y-3 text-xs text-slate-300">
              <li className="flex items-center space-x-2">
                <span className="w-2 h-2 rounded-full bg-cyan-400" />
                <span><strong>本機運算首選</strong>：:5112 HMAC 認證通道，隔離外接請求</span>
              </li>
              <li className="flex items-center space-x-2">
                <span className="w-2 h-2 rounded-full bg-cyan-400" />
                <span><strong>嚴格 Token 授權</strong>：gateway 路由除了公開健康檢查外全數要求認證</span>
              </li>
              <li className="flex items-center space-x-2">
                <span className="w-2 h-2 rounded-full bg-cyan-400" />
                <span><strong>無命令執行風險</strong>：安全 API 表面，防範遠端 shell / 命令注入</span>
              </li>
            </ul>
          </div>

          <div className="glass-panel border border-white/10 p-6 rounded-2xl">
            <h4 className="text-xs font-mono text-cyan-400 mb-4 uppercase tracking-wider">Privacy & Zero-Cost Policy</h4>
            <div className="space-y-3 text-xs font-mono text-slate-300">
              <div className="p-3 bg-slate-900/60 rounded-lg border border-white/5">
                <span className="text-green-400">✓ PRIVACY_MODE = TRUE</span>
                <p className="text-[11px] text-slate-400 mt-1">100% 離線處理，完全封鎖網路請求</p>
              </div>
              <div className="p-3 bg-slate-900/60 rounded-lg border border-white/5">
                <span className="text-cyan-400">✓ LOCAL_MLX_GATEWAY (:5112)</span>
                <p className="text-[11px] text-slate-400 mt-1">16kHz WAV 規範化 + 本地詞彙標點修正</p>
              </div>
              <div className="p-3 bg-slate-900/60 rounded-lg border border-white/5">
                <span className="text-purple-400">✓ OPT-IN CLOUD ROUTING</span>
                <p className="text-[11px] text-slate-400 mt-1">使用者顯式授權 + 憑證設定方可開啟</p>
              </div>
            </div>
          </div>
        </div>
      </section>

      {/* Section 5: AI Setup 3 Steps */}
      <section id="ai-setup" className="py-16 px-4 md:px-8 max-w-6xl mx-auto border-t border-white/10">
        <div className="text-center mb-12">
          <h3 className="text-3xl font-bold text-white mb-3">AI 自動配置 3 步驟</h3>
          <p className="text-slate-400 text-sm">提供 AI Agent 可相容之 REST / CLI 診斷介面 (server/agent_cli.py)</p>
        </div>

        <div className="grid md:grid-cols-3 gap-6">
          <div className="glass-card p-6 rounded-2xl border border-white/10">
            <div className="w-8 h-8 rounded-lg bg-cyan-500/20 border border-cyan-500/40 text-cyan-300 flex items-center justify-center font-mono font-bold text-sm mb-4">
              01
            </div>
            <h4 className="text-base font-semibold text-white mb-2">自動偵測環境能力</h4>
            <p className="text-xs text-slate-400 leading-relaxed mb-3">
              執行 `python3 server/agent_cli.py capabilities` 探測本機 MLX 與 Ollama 算力。
            </p>
          </div>

          <div className="glass-card p-6 rounded-2xl border border-white/10">
            <div className="w-8 h-8 rounded-lg bg-cyan-500/20 border border-cyan-500/40 text-cyan-300 flex items-center justify-center font-mono font-bold text-sm mb-4">
              02
            </div>
            <h4 className="text-base font-semibold text-white mb-2">一鍵健康檢查 Doctor</h4>
            <p className="text-xs text-slate-400 leading-relaxed mb-3">
              執行 `python3 server/agent_cli.py doctor` 驗證 Token、音訊與系統相容性。
            </p>
          </div>

          <div className="glass-card p-6 rounded-2xl border border-white/10">
            <div className="w-8 h-8 rounded-lg bg-cyan-500/20 border border-cyan-500/40 text-cyan-300 flex items-center justify-center font-mono font-bold text-sm mb-4">
              03
            </div>
            <h4 className="text-base font-semibold text-white mb-2">嚴格設定 Schema 驗證</h4>
            <p className="text-xs text-slate-400 leading-relaxed mb-3">
              讀取 `config-schema` 並透過 HTTP POST (`/api/settings`) 安全更新本機與雲端模型路由。
            </p>
          </div>
        </div>
      </section>

      {/* Section 6: REST / OpenAI API Examples */}
      <section id="api" className="py-16 px-4 md:px-8 max-w-6xl mx-auto border-t border-white/10">
        <div className="text-center mb-10">
          <h3 className="text-3xl font-bold text-white mb-3">REST & OpenAI-Compatible Subset API</h3>
          <p className="text-slate-400 text-sm">提供 OpenAI 相容子集端點，可直接整合自動化腳本或第三方應用</p>
        </div>

        <div className="glass-panel border border-white/10 rounded-2xl p-6 overflow-x-auto font-mono text-xs text-slate-300">
          <div className="flex items-center space-x-2 border-b border-white/10 pb-3 mb-4 text-slate-400">
            <span className="text-cyan-400 font-bold">POST</span>
            <span>http://127.0.0.1:5111/v1/audio/transcriptions</span>
          </div>
          <pre className="text-cyan-300">{`curl -X POST http://127.0.0.1:5111/v1/audio/transcriptions \\
  -H "X-NexVoice-Token: $GATEWAY_TOKEN" \\
  -F "file=@recording.wav" \\
  -F "model=mlx-community/whisper-large-v3-turbo"

# Response:
# { "text": "歡迎使用 NexVoice 語音聽寫服務。" }`}</pre>
        </div>
      </section>

      {/* Section 7: FAQ */}
      <section id="faq" className="py-16 px-4 md:px-8 max-w-4xl mx-auto border-t border-white/10">
        <h3 className="text-3xl font-bold text-white text-center mb-10">常見問題 FAQ</h3>
        <div className="space-y-4">
          <div className="glass-card p-5 rounded-xl border border-white/10">
            <h4 className="text-sm font-semibold text-white mb-1">Q: NexVoice 是否需要付費 API 金鑰才能使用？</h4>
            <p className="text-xs text-slate-400">不需要。NexVoice 預設使用 Apple Silicon 晶片跑本機 MLX Whisper 模型，完全免費且無需連網。</p>
          </div>
          <div className="glass-card p-5 rounded-xl border border-white/10">
            <h4 className="text-sm font-semibold text-white mb-1">Q: 為什麼按熱鍵後沒有反應？</h4>
            <p className="text-xs text-slate-400">請確認 macOS 系統設定 → 隱私權與安全性 →「麥克風」與「輔助功能」已授權給 NexVoice.app。</p>
          </div>
          <div className="glass-card p-5 rounded-xl border border-white/10">
            <h4 className="text-sm font-semibold text-white mb-1">Q: 系統硬體需求為何？</h4>
            <p className="text-xs text-slate-400">專為 macOS 14.0 及 Apple Silicon 晶片 (arm64) 打造，本機 MLX 運算需要 Apple Silicon。</p>
          </div>
        </div>
      </section>

      {/* Footer */}
      <footer className="py-8 px-6 border-t border-white/10 text-center text-xs text-slate-500 flex flex-col items-center gap-3">
        <div className="flex items-center space-x-6 text-slate-400 font-medium">
          <a
            href="https://github.com/awe7893625/nexvoice"
            target="_blank"
            rel="noopener noreferrer"
            className="hover:text-cyan-400 transition-colors"
          >
            Source
          </a>
          <a
            href="https://github.com/awe7893625/nexvoice/issues"
            target="_blank"
            rel="noopener noreferrer"
            className="hover:text-cyan-400 transition-colors"
          >
            Issues
          </a>
          <a
            href="https://github.com/awe7893625/nexvoice/releases"
            target="_blank"
            rel="noopener noreferrer"
            className="hover:text-cyan-400 transition-colors"
          >
            Releases
          </a>
        </div>
        <p>NexVoice Open Source · MIT License · Clean Codebase Claims Preserved</p>
      </footer>
    </main>
  );
}
