#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
生成鸿蒙工程所需的占位图标 PNG（纯标准库，无第三方依赖）。
用途：app_icon / layered_image / startIcon。
可随时用真实设计稿替换同名文件。
"""
import struct
import zlib
import os


def png_bytes(width, height, pixel_fn):
    """pixel_fn(x, y) -> (r, g, b, a)"""
    raw = bytearray()
    for y in range(height):
        raw.append(0)  # filter type 0 (None)
        for x in range(width):
            r, g, b, a = pixel_fn(x, y)
            raw += bytes((r, g, b, a))

    def chunk(tag, data):
        c = struct.pack('>I', len(data)) + tag + data
        c += struct.pack('>I', zlib.crc32(tag + data) & 0xFFFFFFFF)
        return c

    ihdr = struct.pack('>IIBBBBB', width, height, 8, 6, 0, 0, 0)
    out = b'\x89PNG\r\n\x1a\n'
    out += chunk(b'IHDR', ihdr)
    out += chunk(b'IDAT', zlib.compress(bytes(raw), 9))
    out += chunk(b'IEND', b'')
    return out


BG = (13, 17, 23, 255)        # #0D1117 深底
FG = (47, 129, 247, 255)      # #2F81F7 主色
FG2 = (88, 166, 255, 255)     # #58A6FF 亮色


def rounded_rect(x, y, w, h, r, color, canvas_w, canvas_h):
    """返回一个判断函数：点是否落在圆角矩形内"""
    x0, y0, x1, y1 = x, y, x + w, y + h

    def inside(px, py):
        if px < x0 or px >= x1 or py < y0 or py >= y1:
            return False
        # 四角做圆角裁剪
        for cx, cy in ((x0 + r, y0 + r), (x1 - r - 1, y0 + r),
                       (x0 + r, y1 - r - 1), (x1 - r - 1, y1 - r - 1)):
            if (px < x0 + r or px > x1 - r - 1) and (py < y0 + r or py > y1 - r - 1):
                if ((px - cx) ** 2 + (py - cy) ** 2) > r * r:
                    return False
        return True
    return inside


def make_icon(size, accent):
    """深底 + 中央圆角方块 + 内嵌亮色圆点，作为可辨识的占位图标"""
    m = int(size * 0.18)
    box = rounded_rect(m, m, size - 2 * m, size - 2 * m, int(size * 0.14), accent, size, size)
    cx, cy = size / 2.0, size / 2.0
    r_in = size * 0.17

    def px(x, y):
        if ((x - cx) ** 2 + (y - cy) ** 2) <= r_in * r_in:
            return BG
        if box(x, y):
            return accent
        return BG
    return png_bytes(size, size, px)


def main():
    targets = [
        (r'E:/ZM/CarHi/harmony/AppScope/resources/base/media/app_icon.png', 512, FG),
        (r'E:/ZM/CarHi/harmony/entry/src/main/resources/base/media/layered_image.png', 512, FG),
        (r'E:/ZM/CarHi/harmony/entry/src/main/resources/base/media/startIcon.png', 512, FG2),
    ]
    for path, size, accent in targets:
        os.makedirs(os.path.dirname(path), exist_ok=True)
        data = make_icon(size, accent)
        with open(path, 'wb') as f:
            f.write(data)
        print('WROTE %-90s %d bytes' % (path, len(data)))


if __name__ == '__main__':
    main()
