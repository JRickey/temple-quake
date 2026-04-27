// QuakeMath.ZC — port of WinQuake/mathlib.{c,h}.
//
// HolyC has no F32 type; vec_t is F64 here. On-disk Quake assets use
// 32-bit floats — readers will widen to F64 at the I/O boundary. Memory
// layouts that interop with progs.dat etc. need explicit U32-bit reads
// rather than reinterpret-as-F64.
//
// HolyC's parametrized #define macros are unreliable when JIT-pushed
// (see devkit/scripts/temple-run.py and the parser errors we caught
// porting this file). So mathlib.h's DotProduct/VectorAdd/...
// preprocessor macros become out-of-line functions here, named to
// match Quake's C-side `_DotProduct` etc. fallbacks. Call sites that
// originally said `DotProduct(a,b)` should be ported to `_DotProduct(a,b)`.

I64 PITCH = 0;
I64 YAW   = 1;
I64 ROLL  = 2;

F64 DEG2RAD(F64 a) {
  return a * pi / 180.0;
}

F64 vec3_origin[3] = {0.0, 0.0, 0.0};

// ----------------------------------------------------------------
// Out-of-line vec3 ops (vanilla Quake exposes both macro and
// function forms; some sites prefer the function for variadic
// or function-pointer use).
// ----------------------------------------------------------------

F64 _DotProduct(F64 *v1, F64 *v2) {
  return v1[0]*v2[0] + v1[1]*v2[1] + v1[2]*v2[2];
}

U0 _VectorSubtract(F64 *a, F64 *b, F64 *out) {
  out[0] = a[0] - b[0];
  out[1] = a[1] - b[1];
  out[2] = a[2] - b[2];
}

U0 _VectorAdd(F64 *a, F64 *b, F64 *out) {
  out[0] = a[0] + b[0];
  out[1] = a[1] + b[1];
  out[2] = a[2] + b[2];
}

U0 _VectorCopy(F64 *in, F64 *out) {
  out[0] = in[0];
  out[1] = in[1];
  out[2] = in[2];
}

U0 VectorMA(F64 *a, F64 scale, F64 *b, F64 *c) {
  c[0] = a[0] + scale*b[0];
  c[1] = a[1] + scale*b[1];
  c[2] = a[2] + scale*b[2];
}

I64 VectorCompare(F64 *v1, F64 *v2) {
  I64 i;
  for (i = 0; i < 3; i++) {
    if (v1[i] != v2[i]) {
      return 0;
    }
  }
  return 1;
}

F64 Length(F64 *v) {
  F64 l = v[0]*v[0] + v[1]*v[1] + v[2]*v[2];
  return Sqrt(l);
}

U0 CrossProduct(F64 *v1, F64 *v2, F64 *cross) {
  cross[0] = v1[1]*v2[2] - v1[2]*v2[1];
  cross[1] = v1[2]*v2[0] - v1[0]*v2[2];
  cross[2] = v1[0]*v2[1] - v1[1]*v2[0];
}

F64 VectorNormalize(F64 *v) {
  F64 length;
  F64 ilength;
  length = v[0]*v[0] + v[1]*v[1] + v[2]*v[2];
  length = Sqrt(length);
  if (length) {
    ilength = 1.0 / length;
    v[0] *= ilength;
    v[1] *= ilength;
    v[2] *= ilength;
  }
  return length;
}

U0 VectorInverse(F64 *v) {
  v[0] = -v[0];
  v[1] = -v[1];
  v[2] = -v[2];
}

U0 VectorScale(F64 *in, F64 scale, F64 *out) {
  out[0] = in[0] * scale;
  out[1] = in[1] * scale;
  out[2] = in[2] * scale;
}

I64 Q_log2(I64 val) {
  I64 answer = 0;
  val = val >> 1;
  while (val) {
    answer++;
    val = val >> 1;
  }
  return answer;
}

// ----------------------------------------------------------------
// 3x3 / 3x4 matrix concat — fixed unrolled.
// ----------------------------------------------------------------

U0 R_ConcatRotations(F64 *in1, F64 *in2, F64 *out) {
  // Row-major 3x3, stored as 9 F64 in each pointer.
  out[0*3+0] = in1[0*3+0]*in2[0*3+0] + in1[0*3+1]*in2[1*3+0] + in1[0*3+2]*in2[2*3+0];
  out[0*3+1] = in1[0*3+0]*in2[0*3+1] + in1[0*3+1]*in2[1*3+1] + in1[0*3+2]*in2[2*3+1];
  out[0*3+2] = in1[0*3+0]*in2[0*3+2] + in1[0*3+1]*in2[1*3+2] + in1[0*3+2]*in2[2*3+2];
  out[1*3+0] = in1[1*3+0]*in2[0*3+0] + in1[1*3+1]*in2[1*3+0] + in1[1*3+2]*in2[2*3+0];
  out[1*3+1] = in1[1*3+0]*in2[0*3+1] + in1[1*3+1]*in2[1*3+1] + in1[1*3+2]*in2[2*3+1];
  out[1*3+2] = in1[1*3+0]*in2[0*3+2] + in1[1*3+1]*in2[1*3+2] + in1[1*3+2]*in2[2*3+2];
  out[2*3+0] = in1[2*3+0]*in2[0*3+0] + in1[2*3+1]*in2[1*3+0] + in1[2*3+2]*in2[2*3+0];
  out[2*3+1] = in1[2*3+0]*in2[0*3+1] + in1[2*3+1]*in2[1*3+1] + in1[2*3+2]*in2[2*3+1];
  out[2*3+2] = in1[2*3+0]*in2[0*3+2] + in1[2*3+1]*in2[1*3+2] + in1[2*3+2]*in2[2*3+2];
}

U0 R_ConcatTransforms(F64 *in1, F64 *in2, F64 *out) {
  // Row-major 3x4 (rotation 3x3 + translation column), 12 F64 each.
  out[0*4+0] = in1[0*4+0]*in2[0*4+0] + in1[0*4+1]*in2[1*4+0] + in1[0*4+2]*in2[2*4+0];
  out[0*4+1] = in1[0*4+0]*in2[0*4+1] + in1[0*4+1]*in2[1*4+1] + in1[0*4+2]*in2[2*4+1];
  out[0*4+2] = in1[0*4+0]*in2[0*4+2] + in1[0*4+1]*in2[1*4+2] + in1[0*4+2]*in2[2*4+2];
  out[0*4+3] = in1[0*4+0]*in2[0*4+3] + in1[0*4+1]*in2[1*4+3] + in1[0*4+2]*in2[2*4+3] + in1[0*4+3];
  out[1*4+0] = in1[1*4+0]*in2[0*4+0] + in1[1*4+1]*in2[1*4+0] + in1[1*4+2]*in2[2*4+0];
  out[1*4+1] = in1[1*4+0]*in2[0*4+1] + in1[1*4+1]*in2[1*4+1] + in1[1*4+2]*in2[2*4+1];
  out[1*4+2] = in1[1*4+0]*in2[0*4+2] + in1[1*4+1]*in2[1*4+2] + in1[1*4+2]*in2[2*4+2];
  out[1*4+3] = in1[1*4+0]*in2[0*4+3] + in1[1*4+1]*in2[1*4+3] + in1[1*4+2]*in2[2*4+3] + in1[1*4+3];
  out[2*4+0] = in1[2*4+0]*in2[0*4+0] + in1[2*4+1]*in2[1*4+0] + in1[2*4+2]*in2[2*4+0];
  out[2*4+1] = in1[2*4+0]*in2[0*4+1] + in1[2*4+1]*in2[1*4+1] + in1[2*4+2]*in2[2*4+1];
  out[2*4+2] = in1[2*4+0]*in2[0*4+2] + in1[2*4+1]*in2[1*4+2] + in1[2*4+2]*in2[2*4+2];
  out[2*4+3] = in1[2*4+0]*in2[0*4+3] + in1[2*4+1]*in2[1*4+3] + in1[2*4+2]*in2[2*4+3] + in1[2*4+3];
}

// ----------------------------------------------------------------
// Misc primitives.
// ----------------------------------------------------------------

F64 anglemod(F64 a) {
  // Original uses (int)(a * (65536/360.0)) & 65535 — modular reduce
  // through the fixed-point lattice. Mirrors the C code byte-for-byte.
  I64 q = a * (65536.0 / 360.0);
  return (360.0 / 65536.0) * (q & 65535);
}

U0 AngleVectors(F64 *angles, F64 *forward, F64 *right, F64 *up) {
  F64 angle;
  F64 sr;
  F64 sp;
  F64 sy;
  F64 cr;
  F64 cp;
  F64 cy;

  angle = angles[YAW] * (pi*2 / 360.0);
  sy = Sin(angle);
  cy = Cos(angle);
  angle = angles[PITCH] * (pi*2 / 360.0);
  sp = Sin(angle);
  cp = Cos(angle);
  angle = angles[ROLL] * (pi*2 / 360.0);
  sr = Sin(angle);
  cr = Cos(angle);

  forward[0] = cp*cy;
  forward[1] = cp*sy;
  forward[2] = -sp;
  right[0] = (-1*sr*sp*cy + -1*cr*-sy);
  right[1] = (-1*sr*sp*sy + -1*cr*cy);
  right[2] = -1*sr*cp;
  up[0] = (cr*sp*cy + -sr*-sy);
  up[1] = (cr*sp*sy + -sr*cy);
  up[2] = cr*cp;
}

U0 ProjectPointOnPlane(F64 *dst, F64 *p, F64 *normal) {
  F64 d;
  F64 inv_denom;
  F64 n[3];

  inv_denom = 1.0 / _DotProduct(normal, normal);
  d = _DotProduct(normal, p) * inv_denom;
  n[0] = normal[0] * inv_denom;
  n[1] = normal[1] * inv_denom;
  n[2] = normal[2] * inv_denom;
  dst[0] = p[0] - d * n[0];
  dst[1] = p[1] - d * n[1];
  dst[2] = p[2] - d * n[2];
}

U0 PerpendicularVector(F64 *dst, F64 *src) {
  // assumes src is normalized
  I64 pos = 0;
  I64 i;
  F64 minelem = 1.0;
  F64 tempvec[3];
  F64 a;
  for (i = 0; i < 3; i++) {
    a = src[i];
    if (a < 0.0) {
      a = -a;
    }
    if (a < minelem) {
      pos = i;
      minelem = a;
    }
  }
  tempvec[0] = 0.0;
  tempvec[1] = 0.0;
  tempvec[2] = 0.0;
  tempvec[pos] = 1.0;
  ProjectPointOnPlane(dst, tempvec, src);
  VectorNormalize(dst);
}

U0 RotatePointAroundVector(F64 *dst, F64 *dir, F64 *point, F64 degrees) {
  F64 m[9];
  F64 im[9];
  F64 zrot[9];
  F64 tmpmat[9];
  F64 rot[9];
  F64 vr[3];
  F64 vup[3];
  F64 vf[3];
  I64 i;

  vf[0] = dir[0];
  vf[1] = dir[1];
  vf[2] = dir[2];

  PerpendicularVector(vr, dir);
  CrossProduct(vr, vf, vup);

  m[0*3+0] = vr[0];  m[1*3+0] = vr[1];  m[2*3+0] = vr[2];
  m[0*3+1] = vup[0]; m[1*3+1] = vup[1]; m[2*3+1] = vup[2];
  m[0*3+2] = vf[0];  m[1*3+2] = vf[1];  m[2*3+2] = vf[2];

  MemCpy(im, m, sizeof(im));
  // Transpose the rotation columns: im = m^T (the 3x3 inverse of an
  // orthonormal basis is its transpose).
  im[0*3+1] = m[1*3+0];
  im[0*3+2] = m[2*3+0];
  im[1*3+0] = m[0*3+1];
  im[1*3+2] = m[2*3+1];
  im[2*3+0] = m[0*3+2];
  im[2*3+1] = m[1*3+2];

  MemSet(zrot, 0, sizeof(zrot));
  zrot[0*3+0] = 1.0; zrot[1*3+1] = 1.0; zrot[2*3+2] = 1.0;
  F64 rad = DEG2RAD(degrees);
  zrot[0*3+0] = Cos(rad);
  zrot[0*3+1] = Sin(rad);
  zrot[1*3+0] = -Sin(rad);
  zrot[1*3+1] = Cos(rad);

  R_ConcatRotations(m, zrot, tmpmat);
  R_ConcatRotations(tmpmat, im, rot);

  for (i = 0; i < 3; i++) {
    dst[i] = rot[i*3+0]*point[0] + rot[i*3+1]*point[1] + rot[i*3+2]*point[2];
  }
}

U0 FloorDivMod(F64 numer, F64 denom, I64 *quotient, I64 *rem) {
  I64 q;
  I64 r;
  F64 x;
  if (numer >= 0.0) {
    x = Floor(numer / denom);
    q = x;
    r = Floor(numer - x*denom);
  } else {
    x = Floor(-numer / denom);
    q = -x;
    r = Floor(-numer - x*denom);
    if (r != 0) {
      q--;
      r = denom - r;
    }
  }
  *quotient = q;
  *rem = r;
}

I64 GreatestCommonDivisor(I64 i1, I64 i2) {
  if (i1 > i2) {
    if (i2 == 0) {
      return i1;
    }
    return GreatestCommonDivisor(i2, i1 % i2);
  } else {
    if (i1 == 0) {
      return i2;
    }
    return GreatestCommonDivisor(i1, i2 % i1);
  }
}

I64 Invert24To16(I64 val) {
  // 8.24 -> 16.16 reciprocal. Sentinel for tiny inputs.
  if (val < 256) {
    return 0xFFFFFFFF;
  }
  return (1.0 * 0x10000 * 0x1000000 / val) + 0.5;
}
