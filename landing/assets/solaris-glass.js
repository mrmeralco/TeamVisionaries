/*
  solaris-glass.js: fluted glass over a soft, blurred scene, rendered once into the element's background.

  Two scenes, seen through vertical ribs:
    sunset  (the hero) a setting sun, orange with a peach core and a rose halo, low in a navy sky, behind the
            dark outline of a house with one lit window. Fine ribs smear each slice up and down and shift it a
            little, so the picture reads as glass, never as a drawing.
    band    (the bill band) near-black with one band of orange light whose edge breaks into a sawtooth.

  <section data-glass data-glass-scene="sunset" data-glass-rib="16">
  <section data-glass data-glass-scene="band" data-glass-curve="1.02,-0.16,0.04,0.8" data-glass-rib="40">
    curve (band): y of the light's edge across the width, as start, slope, wave, wave phase (0 top, 1 bottom)
    rib:          rib width in CSS px

  The shader renders once, off screen, and the picture becomes the element's background image: a still that
  costs nothing while the page is read (a live canvas over a section was composited 72px out of place in
  Chrome). It is drawn again when the element changes size. No WebGL: the element keeps its CSS background.
*/
const VERT = 'attribute vec2 p;void main(){gl_Position=vec4(p,0.,1.);}';

const FRAG = `
precision highp float;
uniform vec2 uRes;
uniform float uRib;
uniform vec4 uCurve;
uniform float uScene;
uniform vec2 uSun;

float hash(float n) { return fract(sin(n * 127.1) * 43758.5453); }

/* ---- band: near-black, one band of orange light ---- */
vec3 band(vec2 p) {
  float d = p.y - (uCurve.x + uCurve.y * p.x + uCurve.z * sin(p.x * 4.2 + uCurve.w));
  vec3 col = mix(vec3(0.085, 0.040, 0.018), vec3(0.020, 0.030, 0.035), smoothstep(0.0, 1.0, p.y));
  float lit = smoothstep(-0.34, 0.0, d) * (1.0 - step(0.0, d));
  col = mix(col, vec3(0.957, 0.467, 0.129), pow(lit, 2.4) * 0.95);
  col = mix(col, vec3(1.000, 0.760, 0.560), pow(lit, 7.0) * 0.85);
  float shade = step(0.0, d);
  col = mix(col, vec3(0.26, 0.075, 0.17), shade * exp(-d * 4.0) * 0.95);
  col = mix(col, vec3(0.015, 0.025, 0.03), shade * smoothstep(0.05, 0.6, d));
  return col;
}

/* ---- sunset: the sun behind a house, navy sky ---- */
vec3 sunset(vec2 p) {
  float asp = uRes.x / uRes.y;
  vec3 col = mix(vec3(0.035, 0.06, 0.15), vec3(0.11, 0.20, 0.44), smoothstep(0.0, 0.5, p.y));
  col = mix(col, vec3(0.025, 0.04, 0.10), smoothstep(0.55, 1.0, p.y));
  vec2 q = vec2((p.x - uSun.x) * asp, p.y - uSun.y);
  float r2 = dot(q, q);
  col = mix(col, vec3(0.86, 0.30, 0.47), exp(-r2 / 0.16) * 0.80);
  col = mix(col, vec3(0.957, 0.467, 0.129), smoothstep(0.1, 0.9, exp(-r2 / 0.03)) * 0.95);
  col = mix(col, vec3(1.0, 0.80, 0.60), smoothstep(0.55, 1.0, exp(-r2 / 0.012)) * 0.9);
  float hx = abs((p.x - uSun.x - 0.02) * asp);
  float eaves = uSun.y + 0.20;
  float roofY = uSun.y - 0.06 + hx * 0.95;
  float roof = smoothstep(roofY - 0.02, roofY + 0.02, p.y) * smoothstep(0.30, 0.26, hx) * smoothstep(eaves + 0.03, eaves - 0.01, p.y);
  float walls = smoothstep(0.23, 0.20, hx) * smoothstep(eaves - 0.02, eaves + 0.02, p.y);
  float house = max(roof, walls);
  col = mix(col, vec3(0.025, 0.04, 0.09), house * 0.9);
  float win = smoothstep(0.065, 0.045, hx) * smoothstep(eaves + 0.07, eaves + 0.09, p.y) * smoothstep(eaves + 0.20, eaves + 0.18, p.y);
  col = mix(col, vec3(1.0, 0.70, 0.42), win * 0.85);
  return col;
}

vec3 scene(vec2 s) { return uScene > 0.5 ? sunset(s) : band(s); }

void main() {
  vec2 f = gl_FragCoord.xy;
  float idx = floor(f.x / uRib);
  float u = fract(f.x / uRib) * 2.0 - 1.0;
  vec2 p = vec2(f.x / uRes.x, 1.0 - f.y / uRes.y);
  float cx = (idx + 0.5) * uRib / uRes.x;
  vec3 col;
  if (uScene > 0.5) {
    // fine ribs: each one stretches its slice sideways and smears it up and down, a little out of step
    float sx = cx + u * (uRib / uRes.x) * 1.6;
    float sy = p.y + u * 0.025 + (hash(idx) - 0.5) * 0.03;
    col = vec3(0.0);
    for (int k = 0; k < 7; k++) col += scene(vec2(sx, sy + (float(k) - 3.0) * 0.022));
    col /= 7.0;
    col *= 0.90 + 0.10 * (1.0 - u * u);
    col += vec3(0.10, 0.10, 0.12) * smoothstep(0.90, 1.0, abs(u)) * 0.5;
  } else {
    vec2 s = vec2(cx + u * (uRib / uRes.x) * 0.32, p.y + u * 0.055 + u * u * 0.018);
    col = scene(s);
    col *= 0.80 + 0.20 * (1.0 - u * u);
    col += vec3(0.16, 0.14, 0.12) * smoothstep(0.94, 1.0, abs(u)) * 0.55;
  }
  gl_FragColor = vec4(col, 1.0);
}`;

function renderer() {
  const canvas = document.createElement('canvas');
  const gl = canvas.getContext('webgl', { antialias: false, preserveDrawingBuffer: true });
  if (!gl) return null;
  const sh = (type, src) => { const s = gl.createShader(type); gl.shaderSource(s, src); gl.compileShader(s); return s; };
  const prog = gl.createProgram();
  gl.attachShader(prog, sh(gl.VERTEX_SHADER, VERT));
  gl.attachShader(prog, sh(gl.FRAGMENT_SHADER, FRAG));
  gl.linkProgram(prog);
  if (!gl.getProgramParameter(prog, gl.LINK_STATUS)) return null;
  gl.useProgram(prog);
  gl.bindBuffer(gl.ARRAY_BUFFER, gl.createBuffer());
  gl.bufferData(gl.ARRAY_BUFFER, new Float32Array([-1, -1, 3, -1, -1, 3]), gl.STATIC_DRAW);
  const loc = gl.getAttribLocation(prog, 'p');
  gl.enableVertexAttribArray(loc);
  gl.vertexAttribPointer(loc, 2, gl.FLOAT, false, 0, 0);
  const U = n => gl.getUniformLocation(prog, n);
  // one canvas and one WebGL context draw every glass element in turn
  return (w, h, o) => {
    canvas.width = w; canvas.height = h;
    gl.viewport(0, 0, w, h);
    gl.uniform2f(U('uRes'), w, h);
    gl.uniform1f(U('uRib'), o.rib);
    gl.uniform4f(U('uCurve'), o.curve[0], o.curve[1], o.curve[2], o.curve[3]);
    gl.uniform1f(U('uScene'), o.scene === 'sunset' ? 1 : 0);
    gl.uniform2f(U('uSun'), o.sun[0], o.sun[1]);
    gl.drawArrays(gl.TRIANGLES, 0, 3);
    return canvas.toDataURL('image/jpeg', 0.9);
  };
}

const render = renderer();
if (render) {
  document.querySelectorAll('[data-glass]').forEach(el => {
    const curve = (el.dataset.glassCurve || '1.02,-0.16,0.04,0.8').split(',').map(Number);
    const rib = +el.dataset.glassRib || 40;
    const scene = el.dataset.glassScene || 'band';
    let last = '', timer = 0;
    const paint = () => {
      const dpr = Math.min(window.devicePixelRatio || 1, 1.5);
      const box = el.getBoundingClientRect();
      const w = Math.max(1, Math.round(box.width * dpr)), h = Math.max(1, Math.round(box.height * dpr));
      if (w + 'x' + h === last) return;
      last = w + 'x' + h;
      // the sun sits right of centre on a wide screen, above the words on a narrow one
      const sun = box.width >= 1024 ? [0.62, 0.40] : [0.62, 0.34];
      try {
        el.style.backgroundImage = `url(${render(w, h, { rib: rib * dpr, curve, scene, sun })})`;
        el.style.backgroundSize = '100% 100%';
        el.classList.add('has-glass');
      } catch (e) { console.warn('solaris-glass', e); }
    };
    paint();
    new ResizeObserver(() => { clearTimeout(timer); timer = setTimeout(paint, 120); }).observe(el);
  });
}
