import { useEffect, useRef } from "react";

const VERT = `
attribute vec2 p;
void main() { gl_Position = vec4(p, 0.0, 1.0); }
`;

// Slow flowing blue/violet aurora over near-black, with grain + vignette.
const FRAG = `
precision highp float;
uniform float u_time;
uniform vec2 u_res;

float hash(vec2 p){ return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453); }
float noise(vec2 p){
  vec2 i = floor(p), f = fract(p);
  vec2 u = f * f * (3.0 - 2.0 * f);
  return mix(mix(hash(i), hash(i + vec2(1.0, 0.0)), u.x),
             mix(hash(i + vec2(0.0, 1.0)), hash(i + vec2(1.0, 1.0)), u.x), u.y);
}
float fbm(vec2 p){
  float v = 0.0, a = 0.5;
  for (int i = 0; i < 4; i++) { v += a * noise(p); p *= 2.05; a *= 0.5; }
  return v;
}
void main(){
  vec2 uv = gl_FragCoord.xy / u_res.xy;
  float aspect = u_res.x / u_res.y;
  vec2 p = vec2(uv.x * aspect, uv.y);
  float t = u_time * 0.13;                                    // alive

  // Domain-warped flow → drifting, folding aurora ribbons (monochrome).
  // Lower frequencies = larger, "zoomed-in" shapes.
  vec2 warp = vec2(
    fbm(p * 1.0 + vec2(0.0, t)),
    fbm(p * 1.0 + vec2(3.1, -t * 0.9))
  );
  float f = fbm(p * 1.4 + warp * 2.2 + vec2(t * 0.6, t * 0.25));
  float aurora = pow(f, 1.7);                                 // concentrate into ribbons

  // A faster secondary ribbon for liveliness.
  float ribbon = fbm(p * 2.1 + warp * 1.2 + vec2(-t * 1.1, t * 0.5));
  ribbon = pow(ribbon, 3.0);

  vec3 base = vec3(0.022, 0.024, 0.028);
  vec3 tone = vec3(0.58, 0.60, 0.63);                         // neutral grey, no hue

  vec3 col = base;
  col += tone * aurora * 0.16;                                // a touch more present
  col += tone * ribbon * 0.10;

  col += (hash(gl_FragCoord.xy + t) - 0.5) * 0.014;          // faint grain
  float vig = smoothstep(1.30, 0.25, distance(uv, vec2(0.5)));
  col *= mix(0.7, 1.0, vig);                                  // darker edges
  gl_FragColor = vec4(col, 1.0);
}
`;

/** Animated GLSL gradient background (falls back to transparent if WebGL is
 *  unavailable; renders a single static frame under "reduce motion" or when
 *  `paused` — e.g. while the sandbox card needs the GPU for inference). */
export function ShaderBackground({
  className,
  paused = false,
}: {
  className?: string;
  paused?: boolean;
}) {
  const ref = useRef<HTMLCanvasElement>(null);

  useEffect(() => {
    const canvas = ref.current;
    if (!canvas) return;
    const gl = canvas.getContext("webgl", { alpha: false, antialias: false });
    if (!gl) return;

    const compile = (type: number, src: string) => {
      const s = gl.createShader(type)!;
      gl.shaderSource(s, src);
      gl.compileShader(s);
      return s;
    };
    const prog = gl.createProgram()!;
    gl.attachShader(prog, compile(gl.VERTEX_SHADER, VERT));
    gl.attachShader(prog, compile(gl.FRAGMENT_SHADER, FRAG));
    gl.linkProgram(prog);
    gl.useProgram(prog);

    const buf = gl.createBuffer();
    gl.bindBuffer(gl.ARRAY_BUFFER, buf);
    gl.bufferData(gl.ARRAY_BUFFER, new Float32Array([-1, -1, 3, -1, -1, 3]), gl.STATIC_DRAW);
    const loc = gl.getAttribLocation(prog, "p");
    gl.enableVertexAttribArray(loc);
    gl.vertexAttribPointer(loc, 2, gl.FLOAT, false, 0, 0);

    const uTime = gl.getUniformLocation(prog, "u_time");
    const uRes = gl.getUniformLocation(prog, "u_res");

    const resize = () => {
      const dpr = Math.min(window.devicePixelRatio || 1, 2);
      const w = Math.max(1, Math.floor(canvas.clientWidth * dpr));
      const h = Math.max(1, Math.floor(canvas.clientHeight * dpr));
      if (canvas.width !== w || canvas.height !== h) {
        canvas.width = w;
        canvas.height = h;
      }
      gl.viewport(0, 0, canvas.width, canvas.height);
    };

    const draw = (seconds: number) => {
      resize();
      gl.uniform1f(uTime, seconds);
      gl.uniform2f(uRes, canvas.width, canvas.height);
      gl.drawArrays(gl.TRIANGLES, 0, 3);
    };

    const reduce = window.matchMedia("(prefers-reduced-motion: reduce)").matches;
    if (reduce || paused) {
      draw(8);
      return;
    }

    // ~30fps is plenty for a slow aurora and halves the GPU load (which the
    // local LLM competes for).
    let raf = 0;
    let last = 0;
    const start = performance.now();
    const loop = (now: number) => {
      raf = requestAnimationFrame(loop);
      if (now - last < 33) return;
      last = now;
      draw((now - start) / 1000);
    };
    raf = requestAnimationFrame(loop);
    return () => cancelAnimationFrame(raf);
  }, [paused]);

  return <canvas ref={ref} className={className} />;
}
