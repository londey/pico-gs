"""Pure-Python 3D math helpers for MVP transformation pipeline.

All matrices are stored as flat 16-element lists in **column-major** order
(matching OpenGL / glam convention):

    [m00, m10, m20, m30,   # column 0
     m01, m11, m21, m31,   # column 1
     m02, m12, m22, m32,   # column 2
     m03, m13, m23, m33]   # column 3

Element access: m[col*4 + row]
"""

from __future__ import annotations

import math
from typing import Tuple

Vec3 = Tuple[float, float, float]
Vec4 = Tuple[float, float, float, float]
Mat4 = list  # 16 floats, column-major


def mat4_identity() -> Mat4:
    """Return 4x4 identity matrix."""
    return [
        1, 0, 0, 0,
        0, 1, 0, 0,
        0, 0, 1, 0,
        0, 0, 0, 1,
    ]


def _get(m: Mat4, row: int, col: int) -> float:
    return m[col * 4 + row]


def _set(m: Mat4, row: int, col: int, val: float) -> None:
    m[col * 4 + row] = val


def mat4_mul(a: Mat4, b: Mat4) -> Mat4:
    """Multiply two 4x4 matrices: result = a * b."""
    r = [0.0] * 16
    for col in range(4):
        for row in range(4):
            s = 0.0
            for k in range(4):
                s += _get(a, row, k) * _get(b, k, col)
            _set(r, row, col, s)
    return r


def mat4_mul_vec4(m: Mat4, v: Vec4) -> Vec4:
    """Multiply a 4x4 matrix by a vec4: result = m * v."""
    x, y, z, w = v
    return (
        _get(m, 0, 0) * x + _get(m, 0, 1) * y + _get(m, 0, 2) * z + _get(m, 0, 3) * w,
        _get(m, 1, 0) * x + _get(m, 1, 1) * y + _get(m, 1, 2) * z + _get(m, 1, 3) * w,
        _get(m, 2, 0) * x + _get(m, 2, 1) * y + _get(m, 2, 2) * z + _get(m, 2, 3) * w,
        _get(m, 3, 0) * x + _get(m, 3, 1) * y + _get(m, 3, 2) * z + _get(m, 3, 3) * w,
    )


def mat4_translate(tx: float, ty: float, tz: float) -> Mat4:
    """Return a translation matrix."""
    return [
        1, 0, 0, 0,
        0, 1, 0, 0,
        0, 0, 1, 0,
        tx, ty, tz, 1,
    ]


def mat4_rotate_x(angle: float) -> Mat4:
    """Return a rotation matrix around the X axis (angle in radians)."""
    c = math.cos(angle)
    s = math.sin(angle)
    return [
        1, 0, 0, 0,
        0, c, s, 0,
        0, -s, c, 0,
        0, 0, 0, 1,
    ]


def mat4_rotate_y(angle: float) -> Mat4:
    """Return a rotation matrix around the Y axis (angle in radians)."""
    c = math.cos(angle)
    s = math.sin(angle)
    return [
        c, 0, -s, 0,
        0, 1, 0, 0,
        s, 0, c, 0,
        0, 0, 0, 1,
    ]


def _cross(a: Vec3, b: Vec3) -> Vec3:
    return (
        a[1] * b[2] - a[2] * b[1],
        a[2] * b[0] - a[0] * b[2],
        a[0] * b[1] - a[1] * b[0],
    )


def _sub(a: Vec3, b: Vec3) -> Vec3:
    return (a[0] - b[0], a[1] - b[1], a[2] - b[2])


def _normalize(v: Vec3) -> Vec3:
    length = math.sqrt(v[0] ** 2 + v[1] ** 2 + v[2] ** 2)
    return (v[0] / length, v[1] / length, v[2] / length)


def _dot(a: Vec3, b: Vec3) -> float:
    return a[0] * b[0] + a[1] * b[1] + a[2] * b[2]


def mat4_look_at(eye: Vec3, center: Vec3, up: Vec3) -> Mat4:
    """Right-handed look-at view matrix (camera at eye, looking at center)."""
    f = _normalize(_sub(center, eye))
    s = _normalize(_cross(f, up))
    u = _cross(s, f)
    return [
        s[0], u[0], -f[0], 0,
        s[1], u[1], -f[1], 0,
        s[2], u[2], -f[2], 0,
        -_dot(s, eye), -_dot(u, eye), _dot(f, eye), 1,
    ]


def mat4_perspective(fov_y: float, aspect: float,
                     near: float, far: float) -> Mat4:
    """Right-handed reverse-Z perspective projection matrix.

    Maps Z from [near, far] to [1, 0] (reverse-Z convention):
      - Near plane → NDC Z = 1 → Z-buffer 0xFFFF (white)
      - Far plane  → NDC Z = 0 → Z-buffer 0x0000 (black)

    Z-buffer is cleared to 0x0000 and Z_COMPARE_GEQUAL is used,
    so nearer fragments (higher Z) pass the test against farther
    fragments (lower Z) or the cleared background.
    """
    f = 1.0 / math.tan(fov_y / 2.0)
    # Reverse-Z: near → 1, far → 0
    # Derived from standard RH [0,1] by substituting z' = 1 - z:
    #   m22 = near / (far - near)
    #   m23 = (near * far) / (far - near)
    m = [0.0] * 16
    _set(m, 0, 0, f / aspect)
    _set(m, 1, 1, f)
    _set(m, 2, 2, near / (far - near))
    _set(m, 3, 2, -1.0)
    _set(m, 2, 3, (near * far) / (far - near))
    return m


def perspective_divide(clip: Vec4) -> Tuple[float, float, float, float]:
    """Perform perspective division: clip space → NDC.

    Returns (ndc_x, ndc_y, ndc_z, w) where w is the original clip-space W.
    """
    x, y, z, w = clip
    return (x / w, y / w, z / w, w)


def viewport_transform(ndc_x: float, ndc_y: float, ndc_z: float,
                       width: float, height: float) -> Tuple[float, float, float]:
    """NDC → screen-space pixel coordinates.

    X: (ndc_x + 1) * 0.5 * width
    Y: (1 - ndc_y) * 0.5 * height   (Y-flipped: NDC +Y up → screen +Y down)
    Z: ndc_z clamped to [0, 1]
    """
    sx = (ndc_x + 1.0) * 0.5 * width
    sy = (1.0 - ndc_y) * 0.5 * height
    sz = max(0.0, min(1.0, ndc_z))
    return (sx, sy, sz)


def screen_cross_z(v0: Tuple[float, float], v1: Tuple[float, float],
                   v2: Tuple[float, float]) -> float:
    """Z-component of cross product of screen-space triangle edges.

    Positive = counter-clockwise (front-facing in screen-space Y-down).
    """
    e1x = v1[0] - v0[0]
    e1y = v1[1] - v0[1]
    e2x = v2[0] - v0[0]
    e2y = v2[1] - v0[1]
    return e1x * e2y - e1y * e2x
