/*! Glass Headline Hero — Copyright (c) 2026 Kedhareswer Naidu.
 * MIT License; see notices/GlassHeadlineHero-LICENSE.txt.
 * Source: https://mcp.21st.dev/%40kedhareswer/components/glass-headline-hero
 */
"use client"

import * as React from "react"

/**
 * Glass Headline Hero — a hero section whose headline is thick refractive
 * glass. A slow colour field flows behind it and bends through the letters,
 * with prism fringes at the edges; the light follows the pointer, so the
 * bevels catch sliding highlights and throw a shadow and a caustic behind.
 *
 * The headline stays a real <h1>: every word is a span, laid out by the
 * browser in the host's own font, and the shader draws the glass exactly
 * where each word landed. Search engines, screen readers and text selection
 * all see ordinary text; the glass is paint over it.
 *
 * WebGL2, React is the only import. Without WebGL2 the headline simply shows
 * as solid type over a CSS gradient.
 */

export type HeroAction = {
  label: string
  href?: string
  onClick?: () => void
}

export type GlassHeadlineHeroProps = {
  title: string
  eyebrow?: string
  description?: string
  primaryAction?: HeroAction
  secondaryAction?: HeroAction
  /** Five #rrggbb colours for the field behind the glass: the ground first, then four accents. */
  colors?: string[]
  /** **Must be a definite length.** */
  height?: string
  className?: string
}

// #region glass
export const DEFAULT_COLORS = ["#0D0A14", "#FF5A1F", "#FF9EC1", "#2F4CFF", "#FFE6B8"]

export function hexToRgb(hex: string): number[] | null {
  const m = /^#?([0-9a-f]{6})$/i.exec(hex.trim())
  if (!m) return null
  const v = parseInt(m[1], 16)
  return [((v >> 16) & 255) / 255, ((v >> 8) & 255) / 255, (v & 255) / 255]
}

/** Five colours as flat RGB triples; anything missing or malformed falls back to the default in that slot. */
export function paletteOf(colors: string[] | undefined): number[][] {
  return DEFAULT_COLORS.map((fallback, i) => hexToRgb(colors?.[i] ?? "") ?? (hexToRgb(fallback) as number[]))
}

export function splitWords(title: string): string[] {
  return title.trim().split(/\s+/).filter(Boolean)
}

/** Width of the glass bevel, in mask pixels: a share of the type size, never under 2px. */
export function bevelPx(fontPx: number, scale: number): number {
  return Math.max(2, fontPx * 0.075 * scale)
}

/** How far the glass has formed, t ms after it is ready: an ease-out from clear to full glass. */
export function formed(t: number, ms: number): number {
  const x = Math.min(Math.max(t / ms, 0), 1)
  return 1 - Math.pow(1 - x, 3)
}

/**
 * The same palette as a plain CSS background: what shows before the glass
 * fades in, and instead of it without WebGL2. rgba() throughout, because
 * one malformed colour drops the whole declaration and leaves white behind
 * white type.
 */
export function fallbackBackground(palette: number[][]): string {
  const rgba = (c: number[], a: number) => "rgba(" + c.map((v) => Math.round(v * 255)).join(",") + "," + a + ")"
  return (
    "radial-gradient(60% 50% at 25% 30%," + rgba(palette[1], 0.4) + ",transparent 70%)," +
    "radial-gradient(50% 45% at 78% 35%," + rgba(palette[3], 0.4) + ",transparent 70%)," +
    "radial-gradient(45% 40% at 60% 80%," + rgba(palette[2], 0.27) + ",transparent 70%)," +
    rgba(palette[0], 1)
  )
}

/** Frame-rate-independent approach of `from` toward `to`. */
export function follow(from: number, to: number, dt: number, rate: number): number {
  return to + (from - to) * Math.exp(-rate * dt)
}

/** Where the light drifts when nobody is pointing: a slow Lissajous over the headline. */
export function orbit(t: number): number[] {
  return [0.5 + 0.32 * Math.sin(t * 0.37), 0.56 + 0.16 * Math.sin(t * 0.53 + 1.1)]
}
// #endregion

/** How long the glass takes to form on first paint. */
const FORM_MS = 1100
/** The face's gentle dome comes from a blur this many times wider than the bevel's. */
const DOME = 3
/** Seconds without pointer movement before the light goes back to drifting. */
const IDLE_S = 2.5
/** Frame-time watchdog: this many frames slower than SLOW_FRAME_S switch to the light path. */
const SLOW_FRAME_S = 0.05
const SLOW_FRAMES = 8
/** A frame this slow is a software renderer, not a busy moment: it counts three times over. */
const CRAWL_FRAME_S = 0.15

const VERT = `#version 300 es
in vec2 a_position;
out vec2 vUv;
void main() {
  vUv = a_position * 0.5 + 0.5;
  gl_Position = vec4(a_position, 0.0, 1.0);
}
`

const HEAD = `#version 300 es
precision highp float;
in vec2 vUv;
out vec4 o;
`

// The field behind the glass: domain-warped noise in the palette, with soft
// flowing bands. Smooth colour alone barely shows refraction; bands are what
// visibly bend as they pass behind a letter.
const FIELD =
  HEAD +
  `uniform float u_time;
uniform float u_aspect;
uniform vec3 u_c0;
uniform vec3 u_c1;
uniform vec3 u_c2;
uniform vec3 u_c3;
uniform vec3 u_c4;
uniform float u_octaves;

float hash(vec2 p) { return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453); }
float noise(vec2 p) {
  vec2 i = floor(p);
  vec2 f = fract(p);
  vec2 u = f * f * (3.0 - 2.0 * f);
  return mix(mix(hash(i), hash(i + vec2(1.0, 0.0)), u.x), mix(hash(i + vec2(0.0, 1.0)), hash(i + vec2(1.0, 1.0)), u.x), u.y);
}
float fbm(vec2 p) {
  float v = 0.0;
  float a = 0.5;
  mat2 turn = mat2(0.8, 0.6, -0.6, 0.8);
  for (int i = 0; i < 5; i++) {
    if (float(i) >= u_octaves) break;
    v += a * noise(p);
    p = turn * p * 2.02;
    a *= 0.5;
  }
  return v;
}

void main() {
  vec2 p = vec2(vUv.x * u_aspect, vUv.y) * 1.2;
  float t = u_time * 0.06;
  vec2 q = vec2(fbm(p + vec2(0.0, t)), fbm(p + vec2(5.2, 1.3) - t));
  vec2 r = vec2(fbm(p + 3.5 * q + vec2(1.7, 9.2) + t * 1.4), fbm(p + 3.5 * q + vec2(8.3, 2.8) - t * 1.1));
  float f = fbm(p + 3.0 * r);

  // fbm rarely leaves 0.25..0.8, so the thresholds sit inside that range:
  // set wider, the field is mostly ground and the glass has nothing to bend.
  vec3 col = u_c0;
  col = mix(col, u_c3, smoothstep(0.25, 0.72, q.x) * 0.9);
  col = mix(col, u_c1, smoothstep(0.34, 0.74, f));
  col = mix(col, u_c2, smoothstep(0.42, 0.8, r.y) * 0.8);
  col = mix(col, u_c4, smoothstep(0.55, 0.9, f * r.x * 1.8) * 0.7);

  float bands = 0.5 + 0.5 * sin((f * 7.0 + r.x * 3.0) * 3.14159);
  col *= mix(0.86, 1.1, smoothstep(0.2, 0.8, bands));

  // A faint glow behind the headline: one focal point, and more light for
  // the glass to bend.
  vec2 g = (vUv - vec2(0.5, 0.56)) / vec2(0.5, 0.2);
  col += u_c4 * 0.07 * exp(-dot(g, g));

  // Quieter toward the foot, and a soft scrim where the description and
  // buttons sit, so body copy never lands on a busy patch.
  col *= mix(0.42, 1.0, smoothstep(0.02, 0.62, vUv.y));
  vec2 s = (vUv - vec2(0.5, 0.33)) / vec2(0.32, 0.13);
  col *= 1.0 - 0.4 * exp(-dot(s, s));
  o = vec4(col, 1.0);
}`

// Separable gaussian over the headline mask, one channel per pass. R is the
// bevel (steep at the edge), B the dome that gives each face a little
// curvature, G carries the sharp mask through untouched.
//
// The dome is blurred from the already-blurred bevel, never from the mask:
// its taps sit ~3px apart, and sampling a sharp edge that coarsely aliases
// into a fine grid across every letter. A smooth input cannot alias.
const BLUR =
  HEAD +
  `uniform sampler2D u_src;
uniform vec2 u_step;
uniform float u_radius;
uniform float u_read;
uniform float u_write;
float pick(vec4 t) {
  // 0: the raw mask, ignoring faint anti-alias debris; 1: the bevel; 2: the dome.
  return u_read < 0.5 ? smoothstep(0.06, 1.0, t.r) : u_read < 1.5 ? t.r : t.b;
}
void main() {
  float sigma = max(u_radius * 0.5, 0.5);
  float sum = 0.0;
  float weights = 0.0;
  for (int i = -24; i <= 24; i++) {
    float x = float(i) * u_radius / 24.0;
    float w = exp(-0.5 * x * x / (sigma * sigma));
    sum += pick(texture(u_src, vUv + u_step * x)) * w;
    weights += w;
  }
  vec4 here = texture(u_src, vUv);
  float blurred = sum / weights;
  o = vec4(u_write < 0.5 ? blurred : here.r, here.g, u_write < 0.5 ? here.b : blurred, 1.0);
}`

const GLASS =
  HEAD +
  `uniform sampler2D u_field;
uniform sampler2D u_height;
uniform vec2 u_htexel;
uniform float u_bevel;
uniform float u_aspect;
uniform vec2 u_light;
uniform float u_glass;
uniform float u_form;
uniform vec2 u_res;

float hash(vec2 p) { return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453); }

// A rounded bevel, steep at the letter's edge, plus a gentle dome across the
// face. Flat faces read as panes of one tint, and a stem is a rectangle, so
// every stem looked like a box; the dome makes each one a volume.
float bevel(vec2 p) {
  vec4 t = texture(u_height, p);
  float x = clamp((t.r - 0.5) * 2.0, 0.0, 1.0);
  float edge = sqrt(1.0 - (1.0 - x) * (1.0 - x));
  float dome = clamp((t.b - 0.5) * 2.0, 0.0, 1.0);
  return edge * 0.8 + dome * 0.45;
}

void main() {
  vec2 uv = vUv;
  vec2 hv = texture(u_height, uv).rg;
  // Tight tracking overlaps glyphs, and the canvas leaves faint seams (a few
  // /255) along their edges. Counted as glass, they tint every glyph's box.
  float inside = smoothstep(0.08, 0.92, hv.g) * u_glass * u_form;

  // Slope from a Sobel stencil two texels wide. A bilinear height map has a
  // constant slope inside each texel that jumps at the texel edge; a narrow
  // difference hands those steps to the highlight, which turns them into a
  // fine dot grid across every face that faces the light.
  vec2 dx = vec2(u_htexel.x * 2.0, 0.0);
  vec2 dy = vec2(0.0, u_htexel.y * 2.0);
  float tl = bevel(uv - dx + dy);
  float tc = bevel(uv + dy);
  float tr = bevel(uv + dx + dy);
  float ml = bevel(uv - dx);
  float mr = bevel(uv + dx);
  float bl = bevel(uv - dx - dy);
  float bc = bevel(uv - dy);
  float br = bevel(uv + dx - dy);
  vec2 grad = vec2((tr + 2.0 * mr + br) - (tl + 2.0 * ml + bl), (tl + 2.0 * tc + tr) - (bl + 2.0 * bc + br)) / 16.0 * u_bevel;
  vec3 n = normalize(vec3(-grad * 0.9, 1.0));

  // Light sits above the stage at the pointer.
  vec2 toLight = (u_light - uv) * vec2(u_aspect, 1.0);
  vec3 L = normalize(vec3(toLight, 0.45));
  vec3 halfway = normalize(L + vec3(0.0, 0.0, 1.0));
  float facing = max(dot(n, halfway), 0.0);
  // Two highlights: a pin of light and a soft sheen around it. One broad lobe
  // reads as plastic.
  float pin = pow(facing, 160.0);
  float sheen = pow(facing, 24.0);
  float rim = pow(1.0 - n.z, 2.0);
  // A studio light from above: upper bevels catch it, lower ones fall away.
  float studio = smoothstep(-0.7, 0.7, n.y);

  // Refraction, each channel bent a different amount: the prism fringe.
  vec2 bend = -n.xy * 0.05 * u_form * vec2(1.0 / u_aspect, 1.0);
  vec3 through = vec3(
    texture(u_field, uv + bend * 0.84).r,
    texture(u_field, uv + bend).g,
    texture(u_field, uv + bend * 1.18).b);
  // Light enters on the lit side and gathers along the far inner edge.
  vec2 ld = normalize(toLight + 1e-5);
  float gather = rim * max(dot(normalize(n.xy + 1e-5), -ld), 0.0);
  // The rim does not depend on where the pointer is: glass keeps a bright
  // edge from every angle, which keeps letters far from it legible.
  vec3 glass = through * 0.86 + 0.06
    + rim * mix(0.28, 0.72, studio)
    + sheen * 0.16 + pin * 1.3
    + gather * vec3(1.0, 0.93, 0.82) * 0.55;
  // A thin dark line where the glass meets the air defines the edge.
  float lip = smoothstep(0.42, 0.5, hv.r) * (1.0 - smoothstep(0.5, 0.6, hv.r));
  glass *= 1.0 - 0.28 * lip;

  // Behind the glass: a short contact shadow, cast away from the light. Cast
  // any further (or with a caustic ring) it reads as a second headline.
  vec2 away = normalize(toLight + 1e-5) * vec2(1.0 / u_aspect, 1.0);
  float shade = texture(u_height, uv + away * 0.012).r;
  vec3 bg = texture(u_field, uv).rgb;
  bg *= 1.0 - 0.32 * smoothstep(0.1, 0.7, shade) * u_glass;

  vec3 col = mix(bg, glass, inside);
  col += (hash(floor(uv * u_res)) - 0.5) * 0.018;
  o = vec4(col, 1.0);
}`

const CSS =
  ".ghr-root{position:relative;width:100%;overflow:hidden;color:#FFFFFF;container-type:inline-size;touch-action:pan-y}" +
  ".ghr-canvas{position:absolute;inset:0;display:block;width:100%;height:100%;max-width:none;opacity:0;" +
  "transition:opacity 700ms cubic-bezier(0.23,1,0.32,1)}" +
  ".ghr-root[data-glass='true'] .ghr-canvas{opacity:1}" +
  ".ghr-content{position:relative;z-index:1;display:flex;flex-direction:column;align-items:center;justify-content:center;" +
  "gap:28px;height:100%;padding:72px 24px;box-sizing:border-box;text-align:center}" +
  // The headline never moves: the glass is measured from where it sits, so
  // its entrance is the canvas fading in. The rest rises in behind it.
  ".ghr-eyebrow,.ghr-desc,.ghr-actions{animation:ghr-in 700ms cubic-bezier(0.23,1,0.32,1) both}" +
  ".ghr-desc{animation-delay:120ms}" +
  ".ghr-actions{animation-delay:200ms}" +
  ".ghr-eyebrow{display:inline-flex;align-items:center;height:30px;padding:0 14px;border-radius:999px;font-size:13px;" +
  "font-weight:500;letter-spacing:.08em;text-transform:uppercase;color:rgba(255,255,255,.82);" +
  "border:1px solid rgba(255,255,255,.2);background:rgba(255,255,255,.06);-webkit-backdrop-filter:blur(10px);backdrop-filter:blur(10px)}" +
  ".ghr-title{margin:0;max-width:12ch;font-size:clamp(3.75rem,calc(13cqw + 1.5rem),12.5rem);font-weight:800;line-height:.95;" +
  "letter-spacing:-0.025em;color:#FFFFFF;text-wrap:balance;" +
  // The solid type shown before the glass melts into it rather than
  // vanishing in one frame while the glass is still clear.
  "transition:color 900ms cubic-bezier(0.23,1,0.32,1)}" +
  ".ghr-root[data-glass='true'] .ghr-title{color:transparent}" +
  ".ghr-word::selection{background:rgba(255,255,255,.28)}" +
  ".ghr-desc{margin:0;max-width:38rem;font-size:clamp(1rem,1.7cqw,1.25rem);line-height:1.55;color:rgba(255,255,255,.8)}" +
  ".ghr-actions{display:flex;flex-wrap:wrap;justify-content:center;gap:12px;margin-top:8px}" +
  ".ghr-eyebrow{margin-bottom:-8px}" +
  ".ghr-arrow{margin-left:8px;transition:transform 200ms cubic-bezier(0.23,1,0.32,1)}" +
  ".ghr-btn{display:inline-flex;align-items:center;justify-content:center;height:48px;padding:0 24px;border-radius:999px;" +
  "font:inherit;font-size:15px;font-weight:600;text-decoration:none;cursor:pointer;" +
  "transition:transform 160ms ease-out,background-color 200ms ease,border-color 200ms ease}" +
  ".ghr-btn:active{transform:scale(0.97)}" +
  ".ghr-btn:focus-visible{outline:2px solid #FFFFFF;outline-offset:3px}" +
  ".ghr-primary{border:0;background:#FFFFFF;color:#0D0A14}" +
  ".ghr-secondary{border:1px solid rgba(255,255,255,.24);background:rgba(255,255,255,.07);color:#FFFFFF;" +
  "-webkit-backdrop-filter:blur(10px);backdrop-filter:blur(10px)}" +
  "@media (hover:hover) and (pointer:fine){.ghr-primary:hover{background:#EFEAE2}.ghr-primary:hover .ghr-arrow{transform:translateX(3px)}" +
  ".ghr-secondary:hover{background:rgba(255,255,255,.13);border-color:rgba(255,255,255,.4)}}" +
  "@keyframes ghr-in{from{opacity:0;transform:translateY(12px)}}" +
  "@keyframes ghr-fade{from{opacity:0}}" +
  "@media (prefers-reduced-motion:reduce){.ghr-eyebrow,.ghr-desc,.ghr-actions{animation-name:ghr-fade}}"

type Target = { tex: WebGLTexture; fbo: WebGLFramebuffer; w: number; h: number }
type Prog = { prog: WebGLProgram; u: Record<string, WebGLUniformLocation | null> }

function Action({ action, kind }: { action: HeroAction; kind: "primary" | "secondary" }) {
  const cls = "ghr-btn ghr-" + kind
  const content = (
    <>
      {action.label}
      {kind === "primary" ? (
        <svg className="ghr-arrow" width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2.4" strokeLinecap="round" strokeLinejoin="round" aria-hidden="true">
          <path d="M5 12h14M13 6l6 6-6 6" />
        </svg>
      ) : null}
    </>
  )
  return action.href ? (
    <a className={cls} href={action.href} onClick={action.onClick}>
      {content}
    </a>
  ) : (
    <button type="button" className={cls} onClick={action.onClick}>
      {content}
    </button>
  )
}

export default function GlassHeadlineHero({
  title,
  eyebrow,
  description,
  primaryAction,
  secondaryAction,
  colors,
  height = "100svh",
  className = "",
}: GlassHeadlineHeroProps) {
  const rootRef = React.useRef<HTMLElement | null>(null)
  const canvasRef = React.useRef<HTMLCanvasElement | null>(null)
  const titleRef = React.useRef<HTMLHeadingElement | null>(null)
  const [glass, setGlass] = React.useState(false)
  const [generation, setGeneration] = React.useState(0)

  const palette = paletteOf(colors)
  const words = splitWords(title)
  // The engine reads these live, so a new palette or title never rebuilds the GL context.
  const live = React.useRef({ palette, title })
  live.current = { palette, title }
  const pointer = React.useRef({ x: 0.5, y: 0.56, at: -1e9, rebuild: () => {}, kick: () => {} })

  React.useEffect(() => {
    const root = rootRef.current
    const canvas = canvasRef.current
    if (!root || !canvas) return
    const gl = canvas.getContext("webgl2", { alpha: false, antialias: false, depth: false, stencil: false })
    if (!gl) return
    const floatTargets = !!gl.getExtension("EXT_color_buffer_float")

    let disposed = false
    let raf = 0
    let last = 0
    let time = 0
    let inView = true
    let lite = false
    let judged = 0
    let slow = 0
    const light = { x: 0.5, y: 0.56 }
    let readyAt = -1
    const reduceMq = window.matchMedia("(prefers-reduced-motion: reduce)")

    const shader = (type: number, src: string) => {
      const s = gl.createShader(type)
      if (!s) throw new Error("could not create shader")
      gl.shaderSource(s, src)
      gl.compileShader(s)
      if (!gl.getShaderParameter(s, gl.COMPILE_STATUS)) throw new Error("shader: " + gl.getShaderInfoLog(s))
      return s
    }
    const program = (frag: string): Prog => {
      const prog = gl.createProgram()
      if (!prog) throw new Error("could not create program")
      const v = shader(gl.VERTEX_SHADER, VERT)
      const f = shader(gl.FRAGMENT_SHADER, frag)
      gl.attachShader(prog, v)
      gl.attachShader(prog, f)
      gl.bindAttribLocation(prog, 0, "a_position")
      gl.linkProgram(prog)
      gl.deleteShader(v)
      gl.deleteShader(f)
      if (!gl.getProgramParameter(prog, gl.LINK_STATUS)) throw new Error("link: " + gl.getProgramInfoLog(prog))
      const u: Prog["u"] = {}
      const count = gl.getProgramParameter(prog, gl.ACTIVE_UNIFORMS) as number
      for (let i = 0; i < count; i++) {
        const info = gl.getActiveUniform(prog, i)
        if (info) u[info.name.replace(/^u_/, "")] = gl.getUniformLocation(prog, info.name)
      }
      return { prog, u }
    }

    const owned: { tex: WebGLTexture[]; fbo: WebGLFramebuffer[] } = { tex: [], fbo: [] }
    const makeTarget = (w: number, h: number, precise: boolean): Target => {
      const tex = gl.createTexture()
      const fbo = gl.createFramebuffer()
      if (!tex || !fbo) throw new Error("could not allocate a render target")
      gl.bindTexture(gl.TEXTURE_2D, tex)
      gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MIN_FILTER, gl.LINEAR)
      gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MAG_FILTER, gl.LINEAR)
      gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_S, gl.CLAMP_TO_EDGE)
      gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_T, gl.CLAMP_TO_EDGE)
      // The bevel's height is differentiated for normals; at 8 bits the steps
      // show as terraces in the highlights, so it gets half floats when it can.
      if (precise && floatTargets) gl.texImage2D(gl.TEXTURE_2D, 0, gl.RGBA16F, w, h, 0, gl.RGBA, gl.HALF_FLOAT, null)
      else gl.texImage2D(gl.TEXTURE_2D, 0, gl.RGBA8, w, h, 0, gl.RGBA, gl.UNSIGNED_BYTE, null)
      gl.bindFramebuffer(gl.FRAMEBUFFER, fbo)
      gl.framebufferTexture2D(gl.FRAMEBUFFER, gl.COLOR_ATTACHMENT0, gl.TEXTURE_2D, tex, 0)
      owned.tex.push(tex)
      owned.fbo.push(fbo)
      return { tex, fbo, w, h }
    }
    const releaseTargets = () => {
      for (const t of owned.tex) gl.deleteTexture(t)
      for (const f of owned.fbo) gl.deleteFramebuffer(f)
      owned.tex = []
      owned.fbo = []
    }

    let P: Record<"field" | "blur" | "glass", Prog>
    let field: Target | null = null
    let blurA: Target | null = null
    let blurB: Target | null = null
    let maskTex: WebGLTexture | null = null
    let bevel = 4

    const run = (p: Prog, dst: Target | null, u: Record<string, number | number[] | WebGLTexture>) => {
      gl.useProgram(p.prog)
      let unit = 0
      for (const k in u) {
        const loc = p.u[k]
        if (!loc) continue
        const v = u[k]
        if (typeof v === "number") gl.uniform1f(loc, v)
        else if (Array.isArray(v)) {
          if (v.length === 2) gl.uniform2f(loc, v[0], v[1])
          else gl.uniform3f(loc, v[0], v[1], v[2])
        } else {
          gl.activeTexture(gl.TEXTURE0 + unit)
          gl.bindTexture(gl.TEXTURE_2D, v)
          gl.uniform1i(loc, unit++)
        }
      }
      gl.bindFramebuffer(gl.FRAMEBUFFER, dst ? dst.fbo : null)
      gl.viewport(0, 0, dst ? dst.w : canvas.width, dst ? dst.h : canvas.height)
      gl.drawArrays(gl.TRIANGLE_STRIP, 0, 4)
    }

    // The headline, drawn white on black exactly where the browser put each
    // word, then blurred on the GPU into the bevel's height field.
    // What the mask was last built from. First paint asks for it three or
    // four times over (initial size, the ResizeObserver's first call, fonts
    // ready, the title effect) with nothing changed, and each build is four
    // blur passes: on a software renderer that alone froze the page for
    // seconds. Now a build only happens when this changes.
    let built = ""
    const buildMask = () => {
      const heading = titleRef.current
      if (!heading || !field) return
      const box = root.getBoundingClientRect()
      const scale = lite ? 1 : Math.min(window.devicePixelRatio || 1, 1.5)
      const w = Math.max(1, Math.round(box.width * scale))
      const h = Math.max(1, Math.round(box.height * scale))
      const spans = Array.from(heading.querySelectorAll<HTMLElement>(".ghr-word"))
      const rects = spans.map((span) => span.getBoundingClientRect())
      const cs = getComputedStyle(heading)
      const layout = [w, h, scale, cs.font, cs.letterSpacing]
        .concat(spans.map((span, i) => (span.textContent ?? "") + "@" + Math.round(rects[i].left - box.left) + "," + Math.round(rects[i].top - box.top)))
        .join("|")
      if (layout === built) return
      built = layout
      const cnv = document.createElement("canvas")
      cnv.width = w
      cnv.height = h
      const c = cnv.getContext("2d")
      if (!c) return
      c.fillStyle = "#000"
      c.fillRect(0, 0, w, h)
      const fontPx = parseFloat(cs.fontSize) || 64
      c.setTransform(scale, 0, 0, scale, 0, 0)
      c.font = cs.fontStyle + " " + cs.fontWeight + " " + cs.fontSize + " " + cs.fontFamily
      const spaced = c as CanvasRenderingContext2D & { letterSpacing?: string }
      if ("letterSpacing" in c) spaced.letterSpacing = cs.letterSpacing === "normal" ? "0px" : cs.letterSpacing
      c.fillStyle = "#fff"
      c.textBaseline = "alphabetic"
      spans.forEach((span, i) => {
        const text = span.textContent ?? ""
        const ascent = c.measureText(text).fontBoundingBoxAscent || fontPx * 0.8
        c.fillText(text, rects[i].left - box.left, rects[i].top - box.top + ascent)
      })
      if (!maskTex) maskTex = gl.createTexture()
      gl.bindTexture(gl.TEXTURE_2D, maskTex)
      gl.pixelStorei(gl.UNPACK_FLIP_Y_WEBGL, true)
      gl.texImage2D(gl.TEXTURE_2D, 0, gl.RGBA, gl.RGBA, gl.UNSIGNED_BYTE, cnv)
      gl.pixelStorei(gl.UNPACK_FLIP_Y_WEBGL, false)
      gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MIN_FILTER, gl.LINEAR)
      gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MAG_FILTER, gl.LINEAR)
      gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_S, gl.CLAMP_TO_EDGE)
      gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_T, gl.CLAMP_TO_EDGE)

      if (!blurA || blurA.w !== w || blurA.h !== h) {
        for (const t of [blurA, blurB]) {
          if (!t) continue
          gl.deleteTexture(t.tex)
          gl.deleteFramebuffer(t.fbo)
        }
        blurA = makeTarget(w, h, true)
        blurB = makeTarget(w, h, true)
      }
      bevel = bevelPx(fontPx, scale)
      if (!blurA || !blurB) return
      // Bevel across then down, then the dome across then down from the bevel.
      run(P.blur, blurA, { src: maskTex, step: [1 / w, 0], radius: bevel, read: 0, write: 0 })
      run(P.blur, blurB, { src: blurA.tex, step: [0, 1 / h], radius: bevel, read: 1, write: 0 })
      run(P.blur, blurA, { src: blurB.tex, step: [1 / w, 0], radius: bevel * DOME, read: 1, write: 1 })
      run(P.blur, blurB, { src: blurA.tex, step: [0, 1 / h], radius: bevel * DOME, read: 2, write: 1 })
    }

    const size = () => {
      // Lite draws the glass below CSS resolution and lets the browser scale
      // it up: softer edges, on a device that was dropping frames anyway.
      const dpr = lite ? 0.65 : Math.min(window.devicePixelRatio || 1, 2)
      const w = Math.max(1, Math.round(canvas.clientWidth * dpr))
      const h = Math.max(1, Math.round(canvas.clientHeight * dpr))
      if (canvas.width !== w || canvas.height !== h) {
        canvas.width = w
        canvas.height = h
      }
      // The field is smooth, so it is drawn small and stretched: it costs a
      // fifth of the pixels and looks the same through the glass.
      const fs = lite ? 0.25 : 0.4
      const fw = Math.max(1, Math.round(w * fs))
      const fh = Math.max(1, Math.round(h * fs))
      if (!field || field.w !== fw || field.h !== fh) {
        if (field) {
          gl.deleteTexture(field.tex)
          gl.deleteFramebuffer(field.fbo)
        }
        field = makeTarget(fw, fh, false)
      }
      buildMask()
    }

    const draw = () => {
      if (!field || !blurB) return
      const pal = live.current.palette
      const aspect = canvas.width / canvas.height
      run(P.field, field, { time, aspect, octaves: lite ? 3 : 5, c0: pal[0], c1: pal[1], c2: pal[2], c3: pal[3], c4: pal[4] })
      run(P.glass, null, {
        field: field.tex,
        height: blurB.tex,
        htexel: [1 / blurB.w, 1 / blurB.h],
        bevel,
        aspect,
        light: [light.x, light.y],
        glass: 1,
        form: reduceMq.matches || readyAt < 0 ? 1 : formed(performance.now() - readyAt, FORM_MS),
        res: [canvas.width, canvas.height],
      })
    }

    const animating = () => inView && !document.hidden && !reduceMq.matches
    const frame = (now: number) => {
      raf = 0
      if (disposed) return
      const raw = (now - last) / 1000
      last = now
      const dt = Math.min(raw, 0.1)
      if (!lite && judged < 40 && animating()) {
        judged += 1
        if (judged > 3 && raw > SLOW_FRAME_S) slow += raw > CRAWL_FRAME_S ? 3 : 1
        if (slow >= SLOW_FRAMES) {
          lite = true
          size()
        }
      }
      if (animating()) time += dt
      const pt = pointer.current
      const idle = (now - pt.at) / 1000 > IDLE_S
      const [tx, ty] = idle && animating() ? orbit(time) : [pt.x, pt.y]
      light.x = follow(light.x, tx, dt, idle ? 1.2 : 7)
      light.y = follow(light.y, ty, dt, idle ? 1.2 : 7)
      draw()
      // A hero is on screen a lot: it only keeps drawing while it is visible,
      // the tab is showing and motion is welcome, or while the light is still
      // catching up with the pointer.
      // Catching the light up only matters on screen (reduced motion, say,
      // where the pointer is the only thing that moves it). Off screen or in a
      // hidden tab nothing is drawn at all, glide or no glide.
      const catching = Math.abs(light.x - tx) + Math.abs(light.y - ty) > 0.0015
      const visible = inView && !document.hidden
      const forming = readyAt >= 0 && performance.now() - readyAt < FORM_MS
      if (visible && (animating() || catching || forming)) raf = requestAnimationFrame(frame)
    }
    const kick = () => {
      if (raf || disposed) return
      last = performance.now()
      raf = requestAnimationFrame(frame)
    }
    pointer.current.kick = kick
    pointer.current.rebuild = () => {
      if (disposed) return
      buildMask()
      kick()
    }

    const onLost = (e: Event) => {
      e.preventDefault()
      cancelAnimationFrame(raf)
      raf = 0
    }
    const onRestored = () => setGeneration((g) => g + 1)
    canvas.addEventListener("webglcontextlost", onLost)
    canvas.addEventListener("webglcontextrestored", onRestored)

    try {
      P = { field: program(FIELD), blur: program(BLUR), glass: program(GLASS) }
      const vao = gl.createVertexArray()
      gl.bindVertexArray(vao)
      const buffer = gl.createBuffer()
      gl.bindBuffer(gl.ARRAY_BUFFER, buffer)
      gl.bufferData(gl.ARRAY_BUFFER, new Float32Array([-1, -1, 1, -1, -1, 1, 1, 1]), gl.STATIC_DRAW)
      gl.enableVertexAttribArray(0)
      gl.vertexAttribPointer(0, 2, gl.FLOAT, false, 0, 0)
      size()
    } catch {
      return
    }
    setGlass(true)
    readyAt = performance.now()
    kick()

    // Layout moves the words: resizing the hero, or the host's web font
    // arriving after first paint, both re-run the mask.
    let pending = 0
    const observer = new ResizeObserver(() => {
      cancelAnimationFrame(pending)
      pending = requestAnimationFrame(() => {
        if (disposed) return
        size()
        kick()
      })
    })
    observer.observe(root)
    document.fonts?.ready.then(() => pointer.current.rebuild())
    const io = new IntersectionObserver(([e]) => {
      inView = e.isIntersecting
      if (inView) kick()
    })
    io.observe(root)
    const onVisibility = () => !document.hidden && kick()
    document.addEventListener("visibilitychange", onVisibility)
    reduceMq.addEventListener("change", kick)

    return () => {
      disposed = true
      cancelAnimationFrame(raf)
      cancelAnimationFrame(pending)
      observer.disconnect()
      io.disconnect()
      document.removeEventListener("visibilitychange", onVisibility)
      reduceMq.removeEventListener("change", kick)
      canvas.removeEventListener("webglcontextlost", onLost)
      canvas.removeEventListener("webglcontextrestored", onRestored)
      releaseTargets()
      if (maskTex) gl.deleteTexture(maskTex)
      for (const p of Object.values(P ?? {})) gl.deleteProgram(p.prog)
      setGlass(false)
    }
  }, [generation])

  // A new headline is a new mask.
  React.useEffect(() => pointer.current.rebuild(), [title])

  const onPointerMove = (e: React.PointerEvent<HTMLElement>) => {
    const r = e.currentTarget.getBoundingClientRect()
    const pt = pointer.current
    pt.x = (e.clientX - r.left) / r.width
    pt.y = 1 - (e.clientY - r.top) / r.height
    pt.at = performance.now()
    pt.kick()
  }

  return (
    <section
      ref={rootRef}
      className={"ghr-root " + className}
      style={{ height, background: fallbackBackground(palette) }}
      data-glass={glass}
      onPointerMove={onPointerMove}
    >
      <style>{CSS}</style>
      <canvas ref={canvasRef} className="ghr-canvas" aria-hidden="true" />
      <div className="ghr-content">
        {eyebrow ? <span className="ghr-eyebrow">{eyebrow}</span> : null}
        <h1 ref={titleRef} className="ghr-title">
          {words.map((w, i) => (
            <React.Fragment key={i}>
              <span className="ghr-word">{w}</span>
              {i < words.length - 1 ? " " : null}
            </React.Fragment>
          ))}
        </h1>
        {description ? <p className="ghr-desc">{description}</p> : null}
        {primaryAction || secondaryAction ? (
          <div className="ghr-actions">
            {primaryAction ? <Action action={primaryAction} kind="primary" /> : null}
            {secondaryAction ? <Action action={secondaryAction} kind="secondary" /> : null}
          </div>
        ) : null}
      </div>
    </section>
  )
}
