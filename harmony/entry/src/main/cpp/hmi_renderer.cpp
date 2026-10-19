/*
 * CarHi 车机 HMI 渲染器实现 —— 路线 A1：纯自绘（Skia/OH_Drawing 直接画进编码器 surface）
 *
 * 见 hmi_renderer.h 头注的架构说明。这里只记实现要点：
 *
 * 1) 后端优先级
 *    A. OnScreen（首选）：OH_Drawing_GpuContextCreate + OH_Drawing_SurfaceCreateOnScreen
 *       —— Skia GPU 直接把画面提交到编码器输入 window，零拷贝、可跑满帧率。
 *    B. CPU 位图（兜底）：OH_Drawing_BitmapCreateFromPixels + CanvasBind
 *       —— 画到内存位图，再交给 CanvasEncoder::PushPixels 走**已验证过**的
 *          GL 上传通路。慢，但一定出得了画面。
 *    两者共用同一个 DrawFrame()，所以版式代码只有一份。
 *
 * 2) 文字必须缓存
 *    OH_Drawing 每次 CreateTypography 都要做字形收集与排版（中文尤其贵）。
 *    30fps × 十几个文本 = 每秒几百次排版，会把帧时间吃光。
 *    因此这里做一个**按键值缓存**：同样的「文字+字号+颜色+粗细+对齐+最大宽」
 *    只排版一次，之后复用 OH_Drawing_Typography*。车机 HMI 的文本变化很慢
 *    （距离数字、时钟），命中率极高。
 *
 * 3) 缓存是文件级单例
 *    本模块天然只有一个渲染器实例（napi_init 里的 g_hmi 是单例），
 *    所以缓存放文件级静态变量，Start 时重置、Stop 时释放。
 */

#include "hmi_renderer.h"

#include <algorithm>
#include <chrono>
#include <cmath>
#include <cstdio>
#include <cstring>
#include <hilog/log.h>

#ifndef M_PI
#define M_PI 3.14159265358979323846
#endif

#include <native_drawing/drawing_bitmap.h>
#include <native_drawing/drawing_brush.h>
#include <native_drawing/drawing_canvas.h>
#include <native_drawing/drawing_color.h>
#include <native_drawing/drawing_font_collection.h>
#include <native_drawing/drawing_gpu_context.h>
#include <native_drawing/drawing_path.h>
#include <native_drawing/drawing_pen.h>
#include <native_drawing/drawing_point.h>
#include <native_drawing/drawing_rect.h>
#include <native_drawing/drawing_round_rect.h>
#include <native_drawing/drawing_surface.h>
#include <native_drawing/drawing_text_typography.h>

#define LOG_DOMAIN 0x0001
#define LOG_TAG "CarHiHmi"
#define LOGI(...) OH_LOG_Print(LOG_APP, LOG_INFO, LOG_DOMAIN, LOG_TAG, __VA_ARGS__)
#define LOGW(...) OH_LOG_Print(LOG_APP, LOG_WARN, LOG_DOMAIN, LOG_TAG, __VA_ARGS__)
#define LOGE(...) OH_LOG_Print(LOG_APP, LOG_ERROR, LOG_DOMAIN, LOG_TAG, __VA_ARGS__)

namespace carhi {
namespace {

// ===========================================================================
// 调色板（对齐 design/nav-hmi/index.html 的 CSS 变量）
// ===========================================================================
constexpr uint32_t kBg        = 0xFF0A0C10;
constexpr uint32_t kSurface   = 0xFF141821;
constexpr uint32_t kElevated  = 0xFF1E2430;
constexpr uint32_t kAccent    = 0xFF2E9BFF;
constexpr uint32_t kAccentDim = 0xFF1A3A5C;
constexpr uint32_t kFg1       = 0xFFFFFFFF;
constexpr uint32_t kFg2       = 0xFFC3CBD9;
constexpr uint32_t kFg3       = 0xFF7C879B;
constexpr uint32_t kBorder    = 0xFF232A36;
constexpr uint32_t kMapBg     = 0xFF0E1219;
constexpr uint32_t kMapMinor  = 0xFF161C26;
constexpr uint32_t kMapMajor  = 0xFF1D2531;
constexpr uint32_t kRouteDim  = 0xFF14304C;
constexpr uint32_t kAccentSoft = 0x332E9BFF;   // 12% 强调色（光晕）
constexpr uint32_t kAccentSoft2 = 0x552E9BFF;  // 33%

// ===========================================================================
// 版式（1280×720 基准；由 1920×720 视觉稿按 2/3 折算并对齐到整数）
// ===========================================================================
constexpr double kRailW  = 76.0;    // 左侧图标栏宽
constexpr double kPad    = 18.0;    // 通用外边距
constexpr double kMidW   = 296.0;   // 中列宽
constexpr double kCardX  = kRailW + kPad;        // 94
constexpr double kCardW  = kMidW - kPad * 2.0;   // 260
constexpr double kCardPad = 22.0;                // 卡片内边距

// ===========================================================================
// 复用对象（避免每帧 new/delete）
// ===========================================================================
OH_Drawing_Brush *g_fill = nullptr;
OH_Drawing_Pen *g_pen = nullptr;

/**
 * ★ 全局绘制互斥：所有 HmiRenderer 实例共享**文件级静态资源**
 *   （g_fill / g_pen / g_textSlots 文本缓存），所以「在线渲染线程」与
 *   「离线自检（另一个独立实例）」**必须串行**。
 *
 * 不串行的后果（2026-10-15 查出的真实隐患）：
 *   - 自检开头的 ResetTextCache() 会 Destroy 在线线程**正在 paint 的**
 *     Typography → use-after-free；
 *   - 自检结尾的 DestroyBackend() 会 Destroy g_fill/g_pen → 在线线程
 *     手里那份指针当场失效。
 * 表现会是很随机的崩溃/花屏，且只在「边推流边点自检」时出现 —— 最难查的那类。
 *
 * 代价：自检期间（几毫秒）渲染线程会阻塞一下，可接受。
 */
std::mutex g_drawMutex;

OH_Drawing_Brush *Fill() {
    if (g_fill == nullptr) {
        g_fill = OH_Drawing_BrushCreate();
        OH_Drawing_BrushSetAntiAlias(g_fill, true);
    }
    return g_fill;
}

OH_Drawing_Pen *Stroke() {
    if (g_pen == nullptr) {
        g_pen = OH_Drawing_PenCreate();
        OH_Drawing_PenSetAntiAlias(g_pen, true);
        OH_Drawing_PenSetCap(g_pen, LINE_ROUND_CAP);
        OH_Drawing_PenSetJoin(g_pen, LINE_ROUND_JOIN);
    }
    return g_pen;
}

// ===========================================================================
// 文本排版缓存
// ===========================================================================
struct TextSlot {
    std::string text;
    double size = 0;
    uint32_t color = 0;
    int weight = 0;
    int align = 0;
    double maxWidth = 0;
    OH_Drawing_Typography *typo = nullptr;
    bool valid = false;
};

constexpr int kTextSlots = 32;
TextSlot g_textSlots[kTextSlots];
int g_textCursor = 0;

void ResetTextCache() {
    for (int i = 0; i < kTextSlots; i++) {
        if (g_textSlots[i].typo != nullptr) {
            OH_Drawing_DestroyTypography(g_textSlots[i].typo);
            g_textSlots[i].typo = nullptr;
        }
        g_textSlots[i].valid = false;
    }
    g_textCursor = 0;
}

/**
 * 取（必要时建）一段排版好的文本。
 *
 * 命中条件：文字内容 + 字号 + 颜色 + 字重 + 对齐 + 最大宽度 全部一致。
 * 未命中则覆盖游标处最旧的一条（近似 LRU，对本场景够用）。
 */
OH_Drawing_Typography *GetText(OH_Drawing_FontCollection *fc, const char *text, double size,
                               uint32_t color, int weight, int align, double maxWidth) {
    if (text == nullptr || text[0] == '\0' || fc == nullptr) {
        return nullptr;
    }
    // 1) 查缓存
    for (int i = 0; i < kTextSlots; i++) {
        TextSlot &s = g_textSlots[i];
        if (s.valid && s.size == size && s.color == color && s.weight == weight &&
            s.align == align && s.maxWidth == maxWidth && s.text == text) {
            return s.typo;
        }
    }
    // 2) 未命中：重建
    TextSlot &slot = g_textSlots[g_textCursor];
    g_textCursor = (g_textCursor + 1) % kTextSlots;
    if (slot.typo != nullptr) {
        OH_Drawing_DestroyTypography(slot.typo);
        slot.typo = nullptr;
    }

    OH_Drawing_TypographyStyle *tstyle = OH_Drawing_CreateTypographyStyle();
    OH_Drawing_SetTypographyTextAlign(tstyle, align);
    OH_Drawing_SetTypographyTextMaxLines(tstyle, 8);
    OH_Drawing_TypographyCreate *handler = OH_Drawing_CreateTypographyHandler(tstyle, fc);
    OH_Drawing_TextStyle *style = OH_Drawing_CreateTextStyle();
    OH_Drawing_SetTextStyleColor(style, color);
    OH_Drawing_SetTextStyleFontSize(style, size);
    OH_Drawing_SetTextStyleFontWeight(style, weight);
    OH_Drawing_TypographyHandlerPushTextStyle(handler, style);
    OH_Drawing_TypographyHandlerAddText(handler, text);
    OH_Drawing_Typography *typo = OH_Drawing_CreateTypography(handler);
    OH_Drawing_TypographyLayout(typo, maxWidth);

    OH_Drawing_DestroyTypographyHandler(handler);
    OH_Drawing_DestroyTextStyle(style);
    OH_Drawing_DestroyTypographyStyle(tstyle);

    slot.text = text;
    slot.size = size;
    slot.color = color;
    slot.weight = weight;
    slot.align = align;
    slot.maxWidth = maxWidth;
    slot.typo = typo;
    slot.valid = true;
    return typo;
}

/** 文本宽度（用于「数字 + 单位」这类拼接布局） */
double TextWidth(OH_Drawing_Typography *typo) {
    if (typo == nullptr) {
        return 0;
    }
    double w = OH_Drawing_TypographyGetLongestLine(typo);
    if (w <= 0) {
        w = OH_Drawing_TypographyGetMaxWidth(typo);
    }
    return w > 0 ? w : 0;
}

// ===========================================================================
// 绘制原语
// ===========================================================================
void FillRect(OH_Drawing_Canvas *c, double x, double y, double w, double h, uint32_t color) {
    OH_Drawing_Brush *b = Fill();
    OH_Drawing_BrushSetColor(b, color);
    OH_Drawing_CanvasAttachBrush(c, b);
    OH_Drawing_Rect *r = OH_Drawing_RectCreate((float) x, (float) y, (float) (x + w), (float) (y + h));
    OH_Drawing_CanvasDrawRect(c, r);
    OH_Drawing_RectDestroy(r);
    OH_Drawing_CanvasDetachBrush(c);
}

void FillRoundRect(OH_Drawing_Canvas *c, double x, double y, double w, double h, double rad,
                   uint32_t color) {
    OH_Drawing_Brush *b = Fill();
    OH_Drawing_BrushSetColor(b, color);
    OH_Drawing_CanvasAttachBrush(c, b);
    OH_Drawing_Rect *r = OH_Drawing_RectCreate((float) x, (float) y, (float) (x + w), (float) (y + h));
    OH_Drawing_RoundRect *rr = OH_Drawing_RoundRectCreate(r, (float) rad, (float) rad);
    OH_Drawing_CanvasDrawRoundRect(c, rr);
    OH_Drawing_RoundRectDestroy(rr);
    OH_Drawing_RectDestroy(r);
    OH_Drawing_CanvasDetachBrush(c);
}

void StrokeRoundRect(OH_Drawing_Canvas *c, double x, double y, double w, double h, double rad,
                     uint32_t color, double width) {
    OH_Drawing_Pen *p = Stroke();
    OH_Drawing_PenSetColor(p, color);
    OH_Drawing_PenSetWidth(p, (float) width);
    OH_Drawing_CanvasAttachPen(c, p);
    OH_Drawing_Rect *r = OH_Drawing_RectCreate((float) x, (float) y, (float) (x + w), (float) (y + h));
    OH_Drawing_RoundRect *rr = OH_Drawing_RoundRectCreate(r, (float) rad, (float) rad);
    OH_Drawing_CanvasDrawRoundRect(c, rr);
    OH_Drawing_RoundRectDestroy(rr);
    OH_Drawing_RectDestroy(r);
    OH_Drawing_CanvasDetachPen(c);
}

void FillCircle(OH_Drawing_Canvas *c, double cx, double cy, double r, uint32_t color) {
    OH_Drawing_Brush *b = Fill();
    OH_Drawing_BrushSetColor(b, color);
    OH_Drawing_CanvasAttachBrush(c, b);
    OH_Drawing_Point *pt = OH_Drawing_PointCreate((float) cx, (float) cy);
    OH_Drawing_CanvasDrawCircle(c, pt, (float) r);
    OH_Drawing_PointDestroy(pt);
    OH_Drawing_CanvasDetachBrush(c);
}

void StrokeCircle(OH_Drawing_Canvas *c, double cx, double cy, double r, uint32_t color, double width) {
    OH_Drawing_Pen *p = Stroke();
    OH_Drawing_PenSetColor(p, color);
    OH_Drawing_PenSetWidth(p, (float) width);
    OH_Drawing_CanvasAttachPen(c, p);
    OH_Drawing_Point *pt = OH_Drawing_PointCreate((float) cx, (float) cy);
    OH_Drawing_CanvasDrawCircle(c, pt, (float) r);
    OH_Drawing_PointDestroy(pt);
    OH_Drawing_CanvasDetachPen(c);
}

void Line(OH_Drawing_Canvas *c, double x1, double y1, double x2, double y2, uint32_t color,
          double width) {
    OH_Drawing_Pen *p = Stroke();
    OH_Drawing_PenSetColor(p, color);
    OH_Drawing_PenSetWidth(p, (float) width);
    OH_Drawing_CanvasAttachPen(c, p);
    OH_Drawing_CanvasDrawLine(c, (float) x1, (float) y1, (float) x2, (float) y2);
    OH_Drawing_CanvasDetachPen(c);
}

/** 画一条折线（用于地图路线） */
void Polyline(OH_Drawing_Canvas *c, const double *pts, int count, uint32_t color, double width) {
    if (count < 2) {
        return;
    }
    OH_Drawing_Path *path = OH_Drawing_PathCreate();
    OH_Drawing_PathMoveTo(path, (float) pts[0], (float) pts[1]);
    for (int i = 1; i < count; i++) {
        OH_Drawing_PathLineTo(path, (float) pts[i * 2], (float) pts[i * 2 + 1]);
    }
    OH_Drawing_Pen *p = Stroke();
    OH_Drawing_PenSetColor(p, color);
    OH_Drawing_PenSetWidth(p, (float) width);
    OH_Drawing_CanvasAttachPen(c, p);
    OH_Drawing_CanvasDrawPath(c, path);
    OH_Drawing_CanvasDetachPen(c);
    OH_Drawing_PathDestroy(path);
}

/** 画一段文字。(x,y) = 文本区域左上角 */
void Text(OH_Drawing_Canvas *c, OH_Drawing_FontCollection *fc, const char *s, double x, double y,
          double size, uint32_t color, int weight, int align, double maxWidth) {
    OH_Drawing_Typography *typo = GetText(fc, s, size, color, weight, align, maxWidth);
    if (typo == nullptr) {
        return;
    }
    OH_Drawing_TypographyPaint(typo, c, x, y);
}

/**
 * 把画布裁剪到一个圆角矩形内（配合 CanvasRestore 使用）。
 *
 * 用途：CarWith 的导航卡把**进度条铺满整张卡**当背景，进度条必须被卡的圆角
 * 裁掉四角，否则会画出方角、盖住圆角。
 * 依据：`drawing_canvas.h:735 OH_Drawing_CanvasClipRoundRect`（API 12+，本工程 API 26）。
 */
void ClipRoundRectStart(OH_Drawing_Canvas *c, double x, double y, double w, double h, double rad) {
    OH_Drawing_CanvasSave(c);
    OH_Drawing_Rect *r = OH_Drawing_RectCreate((float) x, (float) y, (float) (x + w), (float) (y + h));
    OH_Drawing_RoundRect *rr = OH_Drawing_RoundRectCreate(r, (float) rad, (float) rad);
    OH_Drawing_CanvasClipRoundRect(c, rr, INTERSECT, true);
    OH_Drawing_RoundRectDestroy(rr);
    OH_Drawing_RectDestroy(r);
}

void ClipEnd(OH_Drawing_Canvas *c) {
    OH_Drawing_CanvasRestore(c);
}

/** 转向动作文案（CarWith 导航卡的 tv_action 位置） */
const char *TurnActionText(int32_t type) {
    switch (type) {
        case HMI_TURN_LEFT: return "左转";
        case HMI_TURN_RIGHT: return "右转";
        case HMI_TURN_STRAIGHT: return "直行";
        case HMI_TURN_ARRIVE: return "到达";
        default: return "";
    }
}

// ===========================================================================
// 图标（统一在 24×24 坐标系里画，再按 s/24 缩放）
// ===========================================================================
struct IconBox {
    double x, y, s;
    double u(double v) const { return x + v * s / 24.0; }
    double v(double w) const { return y + w * s / 24.0; }
    double k(double r) const { return r * s / 24.0; }
};

void IconHome(OH_Drawing_Canvas *c, IconBox b, uint32_t color, double w) {
    OH_Drawing_Path *p = OH_Drawing_PathCreate();
    OH_Drawing_PathMoveTo(p, (float) b.u(3.2), (float) b.v(11.2));
    OH_Drawing_PathLineTo(p, (float) b.u(12), (float) b.v(3.6));
    OH_Drawing_PathLineTo(p, (float) b.u(20.8), (float) b.v(11.2));
    OH_Drawing_PathMoveTo(p, (float) b.u(5.4), (float) b.v(10.2));
    OH_Drawing_PathLineTo(p, (float) b.u(5.4), (float) b.v(20.2));
    OH_Drawing_PathLineTo(p, (float) b.u(18.6), (float) b.v(20.2));
    OH_Drawing_PathLineTo(p, (float) b.u(18.6), (float) b.v(10.2));
    OH_Drawing_PathMoveTo(p, (float) b.u(9.8), (float) b.v(20.2));
    OH_Drawing_PathLineTo(p, (float) b.u(9.8), (float) b.v(14.6));
    OH_Drawing_PathLineTo(p, (float) b.u(14.2), (float) b.v(14.6));
    OH_Drawing_PathLineTo(p, (float) b.u(14.2), (float) b.v(20.2));
    OH_Drawing_Pen *pen = Stroke();
    OH_Drawing_PenSetColor(pen, color);
    OH_Drawing_PenSetWidth(pen, (float) b.k(w));
    OH_Drawing_CanvasAttachPen(c, pen);
    OH_Drawing_CanvasDrawPath(c, p);
    OH_Drawing_CanvasDetachPen(c);
    OH_Drawing_PathDestroy(p);
}

void IconNavi(OH_Drawing_Canvas *c, IconBox b, uint32_t color, double w) {
    OH_Drawing_Path *p = OH_Drawing_PathCreate();
    OH_Drawing_PathMoveTo(p, (float) b.u(12), (float) b.v(3.0));
    OH_Drawing_PathLineTo(p, (float) b.u(21.0), (float) b.v(20.6));
    OH_Drawing_PathLineTo(p, (float) b.u(12), (float) b.v(16.6));
    OH_Drawing_PathLineTo(p, (float) b.u(3.0), (float) b.v(20.6));
    OH_Drawing_PathClose(p);
    OH_Drawing_Brush *br = Fill();
    OH_Drawing_BrushSetColor(br, color);
    OH_Drawing_CanvasAttachBrush(c, br);
    OH_Drawing_CanvasDrawPath(c, p);
    OH_Drawing_CanvasDetachBrush(c);
    OH_Drawing_PathDestroy(p);
    (void) w;
}

void IconGear(OH_Drawing_Canvas *c, IconBox b, uint32_t color, double w) {
    StrokeCircle(c, b.u(12), b.v(12), b.k(3.6), color, b.k(w));
    for (int i = 0; i < 8; i++) {
        double a = i * M_PI / 4.0;
        double x1 = b.u(12) + std::cos(a) * b.k(6.4);
        double y1 = b.v(12) + std::sin(a) * b.k(6.4);
        double x2 = b.u(12) + std::cos(a) * b.k(9.6);
        double y2 = b.v(12) + std::sin(a) * b.k(9.6);
        Line(c, x1, y1, x2, y2, color, b.k(w));
    }
}

/** 转向箭头：0=直行 1=左转 2=右转 3=到达 */
void IconTurn(OH_Drawing_Canvas *c, IconBox b, int type, uint32_t color) {
    OH_Drawing_Path *p = OH_Drawing_PathCreate();
    if (type == HMI_TURN_LEFT) {
        OH_Drawing_PathMoveTo(p, (float) b.u(16.4), (float) b.v(20.6));
        OH_Drawing_PathLineTo(p, (float) b.u(16.4), (float) b.v(11.0));
        OH_Drawing_PathQuadTo(p, (float) b.u(16.4), (float) b.v(7.2), (float) b.u(12.4), (float) b.v(7.2));
        OH_Drawing_PathLineTo(p, (float) b.u(6.0), (float) b.v(7.2));
        OH_Drawing_Pen *pen = Stroke();
        OH_Drawing_PenSetColor(pen, color);
        OH_Drawing_PenSetWidth(pen, (float) b.k(3.0));
        OH_Drawing_CanvasAttachPen(c, pen);
        OH_Drawing_CanvasDrawPath(c, p);
        OH_Drawing_CanvasDetachPen(c);
        // 箭头头部
        OH_Drawing_Path *h = OH_Drawing_PathCreate();
        OH_Drawing_PathMoveTo(h, (float) b.u(6.6), (float) b.v(3.0));
        OH_Drawing_PathLineTo(h, (float) b.u(0.6), (float) b.v(7.2));
        OH_Drawing_PathLineTo(h, (float) b.u(6.6), (float) b.v(11.4));
        OH_Drawing_PathClose(h);
        OH_Drawing_Brush *br = Fill();
        OH_Drawing_BrushSetColor(br, color);
        OH_Drawing_CanvasAttachBrush(c, br);
        OH_Drawing_CanvasDrawPath(c, h);
        OH_Drawing_CanvasDetachBrush(c);
        OH_Drawing_PathDestroy(h);
    } else if (type == HMI_TURN_STRAIGHT) {
        OH_Drawing_PathMoveTo(p, (float) b.u(12), (float) b.v(20.6));
        OH_Drawing_PathLineTo(p, (float) b.u(12), (float) b.v(6.4));
        OH_Drawing_Pen *pen = Stroke();
        OH_Drawing_PenSetColor(pen, color);
        OH_Drawing_PenSetWidth(pen, (float) b.k(3.0));
        OH_Drawing_CanvasAttachPen(c, pen);
        OH_Drawing_CanvasDrawPath(c, p);
        OH_Drawing_CanvasDetachPen(c);
        OH_Drawing_Path *h = OH_Drawing_PathCreate();
        OH_Drawing_PathMoveTo(h, (float) b.u(7.6), (float) b.v(8.0));
        OH_Drawing_PathLineTo(h, (float) b.u(12), (float) b.v(2.2));
        OH_Drawing_PathLineTo(h, (float) b.u(16.4), (float) b.v(8.0));
        OH_Drawing_PathClose(h);
        OH_Drawing_Brush *br = Fill();
        OH_Drawing_BrushSetColor(br, color);
        OH_Drawing_CanvasAttachBrush(c, br);
        OH_Drawing_CanvasDrawPath(c, h);
        OH_Drawing_CanvasDetachBrush(c);
        OH_Drawing_PathDestroy(h);
    } else if (type == HMI_TURN_ARRIVE) {
        StrokeCircle(c, b.u(12), b.v(12), b.k(8.4), color, b.k(2.6));
        FillCircle(c, b.u(12), b.v(12), b.k(3.6), color);
    } else {
        // 默认：右转（与视觉稿一致）
        OH_Drawing_PathMoveTo(p, (float) b.u(7.6), (float) b.v(20.6));
        OH_Drawing_PathLineTo(p, (float) b.u(7.6), (float) b.v(11.0));
        OH_Drawing_PathQuadTo(p, (float) b.u(7.6), (float) b.v(7.2), (float) b.u(11.6), (float) b.v(7.2));
        OH_Drawing_PathLineTo(p, (float) b.u(18.0), (float) b.v(7.2));
        OH_Drawing_Pen *pen = Stroke();
        OH_Drawing_PenSetColor(pen, color);
        OH_Drawing_PenSetWidth(pen, (float) b.k(3.0));
        OH_Drawing_CanvasAttachPen(c, pen);
        OH_Drawing_CanvasDrawPath(c, p);
        OH_Drawing_CanvasDetachPen(c);
        OH_Drawing_Path *h = OH_Drawing_PathCreate();
        OH_Drawing_PathMoveTo(h, (float) b.u(17.4), (float) b.v(3.0));
        OH_Drawing_PathLineTo(h, (float) b.u(23.4), (float) b.v(7.2));
        OH_Drawing_PathLineTo(h, (float) b.u(17.4), (float) b.v(11.4));
        OH_Drawing_PathClose(h);
        OH_Drawing_Brush *br = Fill();
        OH_Drawing_BrushSetColor(br, color);
        OH_Drawing_CanvasAttachBrush(c, br);
        OH_Drawing_CanvasDrawPath(c, h);
        OH_Drawing_CanvasDetachBrush(c);
        OH_Drawing_PathDestroy(h);
    }
    OH_Drawing_PathDestroy(p);
}

void IconPrev(OH_Drawing_Canvas *c, IconBox b, uint32_t color) {
    OH_Drawing_Path *t = OH_Drawing_PathCreate();
    OH_Drawing_PathMoveTo(t, (float) b.u(19.0), (float) b.v(5.0));
    OH_Drawing_PathLineTo(t, (float) b.u(7.4), (float) b.v(12.0));
    OH_Drawing_PathLineTo(t, (float) b.u(19.0), (float) b.v(19.0));
    OH_Drawing_PathClose(t);
    OH_Drawing_Brush *br = Fill();
    OH_Drawing_BrushSetColor(br, color);
    OH_Drawing_CanvasAttachBrush(c, br);
    OH_Drawing_CanvasDrawPath(c, t);
    OH_Drawing_CanvasDetachBrush(c);
    OH_Drawing_PathDestroy(t);
    Line(c, b.u(5.4), b.v(5.0), b.u(5.4), b.v(19.0), color, b.k(2.6));
}

void IconNext(OH_Drawing_Canvas *c, IconBox b, uint32_t color) {
    OH_Drawing_Path *t = OH_Drawing_PathCreate();
    OH_Drawing_PathMoveTo(t, (float) b.u(5.0), (float) b.v(5.0));
    OH_Drawing_PathLineTo(t, (float) b.u(16.6), (float) b.v(12.0));
    OH_Drawing_PathLineTo(t, (float) b.u(5.0), (float) b.v(19.0));
    OH_Drawing_PathClose(t);
    OH_Drawing_Brush *br = Fill();
    OH_Drawing_BrushSetColor(br, color);
    OH_Drawing_CanvasAttachBrush(c, br);
    OH_Drawing_CanvasDrawPath(c, t);
    OH_Drawing_CanvasDetachBrush(c);
    OH_Drawing_PathDestroy(t);
    Line(c, b.u(18.6), b.v(5.0), b.u(18.6), b.v(19.0), color, b.k(2.6));
}

void IconPlay(OH_Drawing_Canvas *c, IconBox b, uint32_t color) {
    OH_Drawing_Path *t = OH_Drawing_PathCreate();
    OH_Drawing_PathMoveTo(t, (float) b.u(7.6), (float) b.v(4.6));
    OH_Drawing_PathLineTo(t, (float) b.u(19.4), (float) b.v(12.0));
    OH_Drawing_PathLineTo(t, (float) b.u(7.6), (float) b.v(19.4));
    OH_Drawing_PathClose(t);
    OH_Drawing_Brush *br = Fill();
    OH_Drawing_BrushSetColor(br, color);
    OH_Drawing_CanvasAttachBrush(c, br);
    OH_Drawing_CanvasDrawPath(c, t);
    OH_Drawing_CanvasDetachBrush(c);
    OH_Drawing_PathDestroy(t);
}

void IconPause(OH_Drawing_Canvas *c, IconBox b, uint32_t color) {
    FillRoundRect(c, b.u(6.6), b.v(4.6), b.k(3.8), b.k(14.8), b.k(1.2), color);
    FillRoundRect(c, b.u(13.6), b.v(4.6), b.k(3.8), b.k(14.8), b.k(1.2), color);
}

void IconDisc(OH_Drawing_Canvas *c, IconBox b, uint32_t color) {
    StrokeCircle(c, b.u(12), b.v(12), b.k(9.0), color, b.k(1.6));
    FillCircle(c, b.u(12), b.v(12), b.k(3.2), color);
}

// ---------------------------------------------------------------------------
// 首页 Dock 图标组（参考 carwith_car_hmi_home.html 的 6 个 SVG）
// 统一 24×24 viewBox、描边式（stroke-width 1.6），与原设计稿一致。
// ---------------------------------------------------------------------------

/** 语音助手：话筒 + 支架 */
void IconVoice(OH_Drawing_Canvas *c, IconBox b, uint32_t color, double w) {
    StrokeCircle(c, b.u(12), b.v(9), b.k(3.2), color, b.k(w));
    Line(c, b.u(12), b.v(12.2), b.u(12), b.v(16.2), color, b.k(w));
    Line(c, b.u(8.5), b.v(16.4), b.u(15.5), b.v(16.4), color, b.k(w));
}

/** 地图：定位水滴 + 圆心 */
void IconMapPin(OH_Drawing_Canvas *c, IconBox b, uint32_t color, double w) {
    OH_Drawing_Path *p = OH_Drawing_PathCreate();
    OH_Drawing_PathMoveTo(p, (float) b.u(12), (float) b.v(21));
    // 水滴两侧由两条对称二次曲线近似（native_drawing 无 arcTo，用 lineTo 折线）
    const int N = 24;
    for (int i = 1; i <= N; i++) {
        double t = (double) i / N;
        double a = M_PI * t;                 // 0 → π 绕上半圈
        double px = b.u(12) - std::sin(a) * b.k(6.5);
        double py = b.v(10.5) + std::cos(a) * b.k(6.5);
        OH_Drawing_PathLineTo(p, (float) px, (float) py);
    }
    OH_Drawing_Pen *pen = Stroke();
    OH_Drawing_PenSetColor(pen, color);
    OH_Drawing_PenSetWidth(pen, (float) b.k(w));
    OH_Drawing_CanvasAttachPen(c, pen);
    OH_Drawing_CanvasDrawPath(c, p);
    OH_Drawing_CanvasDetachPen(c);
    OH_Drawing_PathDestroy(p);
    StrokeCircle(c, b.u(12), b.v(10.5), b.k(2.2), color, b.k(w));
}

/** 音乐：双音符 */
void IconMusic(OH_Drawing_Canvas *c, IconBox b, uint32_t color, double w) {
    StrokeCircle(c, b.u(7), b.v(17), b.k(2.6), color, b.k(w));
    StrokeCircle(c, b.u(17.5), b.v(15), b.k(2.6), color, b.k(w));
    Line(c, b.u(9.6), b.v(17), b.u(9.6), b.v(7.4), color, b.k(w));
    Line(c, b.u(9.6), b.v(7.4), b.u(20.1), b.v(5), color, b.k(w));
    Line(c, b.u(20.1), b.v(5), b.u(20.1), b.v(15), color, b.k(w));
}

/** 通话：听筒 */
void IconPhone(OH_Drawing_Canvas *c, IconBox b, uint32_t color, double w) {
    OH_Drawing_Path *p = OH_Drawing_PathCreate();
    OH_Drawing_PathMoveTo(p, (float) b.u(7), (float) b.v(4));
    OH_Drawing_PathLineTo(p, (float) b.u(9), (float) b.v(8));
    OH_Drawing_PathLineTo(p, (float) b.u(7), (float) b.v(9.5));
    OH_Drawing_PathLineTo(p, (float) b.u(12.5), (float) b.v(15));
    OH_Drawing_PathLineTo(p, (float) b.u(14), (float) b.v(13));
    OH_Drawing_PathLineTo(p, (float) b.u(18), (float) b.v(15));
    OH_Drawing_PathLineTo(p, (float) b.u(18), (float) b.v(18));
    OH_Drawing_PathLineTo(p, (float) b.u(16), (float) b.v(20));
    OH_Drawing_PathLineTo(p, (float) b.u(2), (float) b.v(6));
    OH_Drawing_PathLineTo(p, (float) b.u(4), (float) b.v(4));
    OH_Drawing_PathClose(p);
    OH_Drawing_Pen *pen = Stroke();
    OH_Drawing_PenSetColor(pen, color);
    OH_Drawing_PenSetWidth(pen, (float) b.k(w));
    OH_Drawing_CanvasAttachPen(c, pen);
    OH_Drawing_CanvasDrawPath(c, p);
    OH_Drawing_CanvasDetachPen(c);
    OH_Drawing_PathDestroy(p);
}

/** 更多：2×2 圆角方块 */
void IconGrid(OH_Drawing_Canvas *c, IconBox b, uint32_t color, double w) {
    const double pts[4][2] = {{4, 4}, {13, 4}, {4, 13}, {13, 13}};
    for (int i = 0; i < 4; i++) {
        double x = b.u(pts[i][0]);
        double y = b.v(pts[i][1]);
        double s = b.k(7);
        StrokeRoundRect(c, x, y, s, s, b.k(2), color, b.k(w));
    }
}

/** 信号格（4 根递增竖条，实心） */
void IconSignal(OH_Drawing_Canvas *c, IconBox b, uint32_t color, int bars) {
    const double xs[4] = {0, 4.5, 9, 13.5};
    const double ys[4] = {8, 5.5, 3, 0.5};
    const double hs[4] = {4, 6.5, 9, 11.5};
    for (int i = 0; i < 4; i++) {
        uint32_t col = (i < bars) ? color : 0xFF3A424E;
        FillRoundRect(c, b.u(xs[i]), b.v(ys[i]), b.k(2.5), b.k(hs[i]), b.k(1), col);
    }
}

/** 电池：外框 + 正极 + 按百分比填充（0-100） */
void IconBattery(OH_Drawing_Canvas *c, IconBox b, uint32_t color, int pct) {
    if (pct < 0) { pct = 0; }
    if (pct > 100) { pct = 100; }
    // 外框（宽 21 高 11.5 @24 网格）
    StrokeRoundRect(c, b.u(0.75), b.v(0.75), b.k(21), b.k(11.5), b.k(3), color, b.k(1.5));
    // 正极
    Line(c, b.u(24), b.v(4.5), b.u(24), b.v(8.5), color, b.k(1.6));
    // 电量
    double w = b.k(15) * pct / 100.0;
    if (w > b.k(1)) {
        FillRoundRect(c, b.u(3), b.v(3), w, b.k(7), b.k(1.5), color);
    }
}

} // namespace

// ===========================================================================
// HmiRenderer
// ===========================================================================

HmiRenderer::~HmiRenderer() {
    Stop();
}

int32_t HmiRenderer::Start(OHNativeWindow *window, int32_t width, int32_t height, int32_t fps,
                           LogCallback onLog) {
    if (running_.load()) {
        LOGW("HmiRenderer already running");
        return 0;
    }
    if (window == nullptr || width <= 0 || height <= 0) {
        LOGE("HmiRenderer::Start 参数非法 window=%p %dx%d", window, width, height);
        return 1;
    }
    {
        std::lock_guard<std::mutex> guard(lock_);
        window_ = window;
        width_ = width;
        height_ = height;
        fps_ = (fps >= 1 && fps <= 120) ? fps : 30;
        onLog_ = std::move(onLog);
        stateDirty_.store(true);
    }
    {
        std::lock_guard<std::mutex> guard(readyLock_);
        ready_ = false;
        startResult_ = 0;
    }
    threadExited_.store(false);
    running_.store(true);
    thread_ = std::thread(&HmiRenderer::ThreadMain, this);

    // 等后端建好（最多 3 秒），把创建结果如实报给调用方
    std::unique_lock<std::mutex> lk(readyLock_);
    readyCv_.wait_for(lk, std::chrono::seconds(3), [this] { return ready_; });
    return startResult_;
}

void HmiRenderer::Stop() {
    if (!running_.exchange(false)) {
        return;
    }
    if (thread_.joinable()) {
        thread_.join();
    }
    LOGI("HmiRenderer stopped, frames=%{public}llu",
         static_cast<unsigned long long>(frameCount_.load()));
}

void HmiRenderer::SetState(const HmiState &state) {
    {
        std::lock_guard<std::mutex> guard(lock_);
        state_ = state;
        stateDirty_.store(true);
    }
}

void HmiRenderer::SetCpuPresenter(PresentCpuCallback cb) {
    std::lock_guard<std::mutex> guard(lock_);
    presentCpu_ = std::move(cb);
}

void HmiRenderer::SetOutputFramesProbe(OutputFramesCallback cb) {
    std::lock_guard<std::mutex> guard(lock_);
    outputFramesProbe_ = std::move(cb);
}

void HmiRenderer::SetGlReleaser(ReleaseGlCallback cb) {
    std::lock_guard<std::mutex> guard(lock_);
    releaseGl_ = std::move(cb);
}

void HmiRenderer::RequestBackend(int32_t backend) {
    if (backend != BACKEND_AUTO && backend != BACKEND_GPU && backend != BACKEND_CPU) {
        LOGW("RequestBackend 收到非法值 %{public}d，忽略", backend);
        return;
    }
    requestedBackend_.store(backend);
    LOGI("RequestBackend -> %{public}d", backend);
}

void HmiRenderer::Log(const std::string &msg) {
    LogCallback cb;
    {
        std::lock_guard<std::mutex> guard(lock_);
        cb = onLog_;
    }
    if (cb) {
        cb(msg);
    }
}

// ---------------------------------------------------------------------------
// 渲染线程
// ---------------------------------------------------------------------------

void HmiRenderer::ThreadMain() {
    // 字体集合：整线程共用一份（SDK 要求多个 TypographyCreate 共用一个
    // collection 时用 CreateSharedFontCollection）
    fontCollection_ = OH_Drawing_CreateSharedFontCollection();

    bool ok = CreateBackend();
    {
        std::lock_guard<std::mutex> guard(readyLock_);
        startResult_ = ok ? 0 : 1;
        ready_ = true;
    }
    readyCv_.notify_all();
    if (!ok) {
        running_.store(false);
        threadExited_.store(true);
        return;
    }

    Log(usingCpuBackend_.load()
            ? "HMI 渲染已启动（CPU 位图后端 → GL 上传）"
            : "HMI 渲染已启动（GPU OnScreen 后端，零拷贝）");
    currentBackend_.store(usingCpuBackend_.load() ? 1 : 0);

    const auto frameInterval = std::chrono::microseconds(1000000 / (fps_ > 0 ? fps_ : 30));
    auto nextTick = std::chrono::steady_clock::now();

    // -----------------------------------------------------------------------
    // 后端自愈看门狗（2026-10-16 重做：**持续生效 + 冷却**）
    //
    // 判据：我们**提交了**帧、而编码器**输出帧数没涨**（持续 kStallMs）。
    //       这只有一种解释：画的东西没进编码器（A2 的原始症状）。
    // 动作：退 CPU 位图后端（那条 GL 上传通路 2026-10-13 实测出过帧）。
    //
    // ★ 为什么把「只在前 6 秒判 2 次」改成「任何时候都能判」：
    //   真机实测到的冻结是
    //     `★ 自愈触发：GPU 后端已提交 181 帧，编码器输出仍为 2（3006ms 无增长）`
    //   —— 3 秒才第一次命中，正好落在旧预算内，所以看起来"有效"。
    //   但旧实现用 `healBudget = 2` 把自愈**永久锁死在启动头 6 秒**：
    //     · 用户若在 6 秒后手动切回 GPU → 停帧后**再也救不回来**；
    //     · GPU 后端若在 6 秒之后才停帧 → 同样救不回来。
    //   那才是真正的「GPU 冻结不可自愈」。现在改成持续判定，
    //   两次自愈之间只用冷却时间防抖（避免编码器瞬时抖动引发"手术治感冒"）。
    // -----------------------------------------------------------------------
    constexpr int64_t kStallMs = 1500;         // 判定"停帧"所需的无增长时长
    constexpr int64_t kHealCooldownMs = 5000;  // 两次自愈之间的最小间隔（防抖）
    auto watchStart = std::chrono::steady_clock::now();
    auto lastHealAt = std::chrono::steady_clock::now()
                      - std::chrono::milliseconds(kHealCooldownMs);
    uint64_t watchBaseOut = 0;
    bool haveProbe = false;
    {
        std::lock_guard<std::mutex> guard(lock_);
        if (outputFramesProbe_) {
            watchBaseOut = outputFramesProbe_();
            haveProbe = true;
        }
    }

    int diagFrames = 0;
    while (running_.load()) {
        // ---- 1) 消费上层的手动后端切换请求 ----
        int32_t req = requestedBackend_.load();
        if (req == BACKEND_CPU && !usingCpuBackend_.load()) {
            Log("收到手动切换请求 → CPU 位图后端");
            if (RebuildBackend(true)) {
                // 注意：这是用户主动切的，**不算自愈** —— 别把 selfHealed_ 置真，
                // 否则诊断里会显示「★已自愈」，误导排查方向。
                selfHealed_.store(false);
            } else {
                LOGE("切换到 CPU 后端失败");
            }
            requestedBackend_.store(BACKEND_AUTO);
            watchStart = std::chrono::steady_clock::now();
            watchBaseOut = 0;
        } else if (req == BACKEND_GPU && usingCpuBackend_.load()) {
            Log("收到手动切换请求 → GPU OnScreen 后端");
            if (RebuildBackend(false)) {
                // 用户明确要 GPU，先按他的意思跑；但若真的停帧，
                // 看门狗仍会在冷却期过后救回来（冻结的画面比"尊重选择"更糟）。
                selfHealed_.store(false);
            } else {
                LOGE("切换到 GPU 后端失败");
            }
            requestedBackend_.store(BACKEND_AUTO);
            watchStart = std::chrono::steady_clock::now();
            watchBaseOut = 0;
        }

        RenderOnce();
        if (diagFrames < 3) {
            LOGI("HMI 帧 #%{public}d 已提交，backend=%{public}s flushCode=%{public}d",
                 diagFrames + 1, usingCpuBackend_.load() ? "cpu" : "gpu", lastFlushCode_.load());
            diagFrames++;
        }

        // ---- 2) 自愈：提交了帧但编码器不出帧 → 换后端 ----
        if (haveProbe && !usingCpuBackend_.load()) {
            auto now = std::chrono::steady_clock::now();
            auto elapsedMs =
                std::chrono::duration_cast<std::chrono::milliseconds>(now - watchStart).count();
            if (elapsedMs >= kStallMs) {
                uint64_t outNow = 0;
                {
                    std::lock_guard<std::mutex> guard(lock_);
                    if (outputFramesProbe_) {
                        outNow = outputFramesProbe_();
                    }
                }
                if (outNow <= watchBaseOut) {
                    auto sinceHealMs = std::chrono::duration_cast<std::chrono::milliseconds>(
                        now - lastHealAt).count();
                    if (sinceHealMs >= kHealCooldownMs) {
                        LOGW("★ 自愈触发：GPU 后端已提交 %{public}llu 帧，编码器输出仍为 "
                             "%{public}llu（%{public}lldms 无增长）→ 退 CPU 位图后端",
                             static_cast<unsigned long long>(frameCount_.load()),
                             static_cast<unsigned long long>(outNow),
                             static_cast<long long>(elapsedMs));
                        if (RebuildBackend(true)) {
                            selfHealed_.store(true);
                            lastHealAt = now;
                        } else {
                            LOGE("自愈失败：CPU 后端也建不起来，停止渲染");
                            running_.store(false);
                            break;
                        }
                    }
                }
                watchStart = now;
                watchBaseOut = outNow;
            }
        }

        nextTick += frameInterval;
        auto nowTick = std::chrono::steady_clock::now();
        if (nextTick > nowTick) {
            std::this_thread::sleep_for(nextTick - nowTick);
        } else {
            // 落后了就重排，避免"追帧"把 CPU 打满
            nextTick = nowTick;
        }
    }

    DestroyBackend();
    // ★ 顺序要紧：缓存里的 Typography 是从 fontCollection_ 派生的，
    //   必须**先销毁 Typography、再销毁 FontCollection**。
    //   （虽然 OH_Drawing_CreateSharedFontCollection 名字里带 shared、
    //     大概率是引用计数，但反过来写没有任何好处，只是把安全性押在实现细节上。）
    ResetTextCache();
    if (fontCollection_ != nullptr) {
        OH_Drawing_DestroyFontCollection(fontCollection_);
        fontCollection_ = nullptr;
    }
    threadExited_.store(true);
}

bool HmiRenderer::CreateGpuBackend() {
    gpuCtx_ = OH_Drawing_GpuContextCreate();
    if (gpuCtx_ == nullptr) {
        LOGE("OH_Drawing_GpuContextCreate 失败");
        return false;
    }
    OH_Drawing_Image_Info info{};
    info.width = width_;
    info.height = height_;
    info.colorType = COLOR_FORMAT_RGBA_8888;
    info.alphaType = ALPHA_FORMAT_OPAQUE;
    surface_ = OH_Drawing_SurfaceCreateOnScreen(gpuCtx_, info, (void *) window_);
    if (surface_ == nullptr) {
        LOGE("OH_Drawing_SurfaceCreateOnScreen 失败（err=%{public}d）",
             (int) OH_Drawing_ErrorCodeGet());
        OH_Drawing_GpuContextDestroy(gpuCtx_);
        gpuCtx_ = nullptr;
        return false;
    }
    canvas_ = OH_Drawing_SurfaceGetCanvas(surface_);
    if (canvas_ == nullptr) {
        LOGE("SurfaceGetCanvas 返回空");
        OH_Drawing_SurfaceDestroy(surface_);
        surface_ = nullptr;
        OH_Drawing_GpuContextDestroy(gpuCtx_);
        gpuCtx_ = nullptr;
        return false;
    }
    LOGI("OH_Drawing OnScreen surface 就绪 %{public}dx%{public}d", width_, height_);
    return true;
}

bool HmiRenderer::CreateCpuBackend() {
    cpuPixels_.assign(static_cast<size_t>(width_) * height_ * 4, 0);
    OH_Drawing_Image_Info info{};
    info.width = width_;
    info.height = height_;
    info.colorType = COLOR_FORMAT_RGBA_8888;
    info.alphaType = ALPHA_FORMAT_OPAQUE;
    cpuBitmap_ = OH_Drawing_BitmapCreateFromPixels(&info, cpuPixels_.data(),
                                                  static_cast<uint32_t>(width_) * 4);
    if (cpuBitmap_ == nullptr) {
        LOGE("OH_Drawing_BitmapCreateFromPixels 失败");
        return false;
    }
    cpuCanvas_ = OH_Drawing_CanvasCreate();
    if (cpuCanvas_ == nullptr) {
        OH_Drawing_BitmapDestroy(cpuBitmap_);
        cpuBitmap_ = nullptr;
        return false;
    }
    OH_Drawing_CanvasBind(cpuCanvas_, cpuBitmap_);
    return true;
}

bool HmiRenderer::CreateBackend() {
    // 用户显式要 CPU → 直接走 CPU
    if (requestedBackend_.load() == BACKEND_CPU) {
        if (CreateCpuBackend()) {
            usingCpuBackend_.store(true);
            return true;
        }
        LOGE("显式指定的 CPU 后端创建失败");
        return false;
    }
    // ★ 2026-10-16 修正：AUTO 默认走 **CPU 位图**，不再"先 GPU 再退"。
    //
    //   依据（真机实测，两轮都复现）：
    //     · `★ 自愈触发：GPU 后端已提交 181 帧，编码器输出仍为 2（3006ms 无增长）`
    //     · `12:20:54  HMI 帧 #1/#2/#3 已提交，backend=gpu flushCode=0`
    //        紧随其后 `encoder output #1: size=29` / `#2: size=23577`，之后再无输出
    //
    //   即：`OH_Drawing_SurfaceCreateOnScreen` 绑到**编码器输入窗口**
    //   （`OH_VideoEncoder_GetSurface()` 返回的 producer 窗口，不是显示窗口）时，
    //   只有创建后的第一帧能进编码器；此后 `OH_Drawing_SurfaceFlush` 仍返回
    //   SUCCESS(0) 却不再产出任何帧 —— **静默停帧**，正是"GPU 冻结"。
    //   而 AUTO 先试 GPU 的代价是**每次启动白冻 1.5 秒画面**再自愈退 CPU，纯亏。
    //
    //   因此：GPU 通路降级为**显式可选**（设置页「GPU」按钮），供平台侧修好后复测；
    //   默认一律走已实测出帧的 CPU 位图 + `PushPixels` GL 上传。
    if (requestedBackend_.load() == BACKEND_GPU) {
        if (CreateGpuBackend()) {
            usingCpuBackend_.store(false);
            return true;
        }
        Log("GPU 表面不可用，退化到 CPU 位图后端");
    }
    if (CreateCpuBackend()) {
        usingCpuBackend_.store(true);
        return true;
    }
    LOGE("CPU 位图后端创建失败");
    return false;
}

bool HmiRenderer::RebuildBackend(bool wantCpu) {
    // 切到 GPU 之前，先让上层把编码器 window 上可能存在的 EGLSurface 解绑。
    // 不这么做的话，CPU 后端留下的 EGLSurface 会和 GPU 表面抢同一个 window。
    if (!wantCpu) {
        ReleaseGlCallback rel;
        {
            std::lock_guard<std::mutex> guard(lock_);
            rel = releaseGl_;
        }
        if (rel) {
            rel();
        }
    }
    DestroyBackend();
    if (wantCpu) {
        if (CreateCpuBackend()) {
            usingCpuBackend_.store(true);
            currentBackend_.store(1);
            return true;
        }
        LOGE("CPU 后端创建失败，尝试恢复 GPU 后端");
        if (CreateGpuBackend()) {
            usingCpuBackend_.store(false);
            currentBackend_.store(0);
            return true;
        }
        return false;
    }
    if (CreateGpuBackend()) {
        usingCpuBackend_.store(false);
        currentBackend_.store(0);
        return true;
    }
    LOGE("GPU 后端创建失败，退回 CPU 后端");
    if (CreateCpuBackend()) {
        usingCpuBackend_.store(true);
        currentBackend_.store(1);
        return true;
    }
    return false;
}

void HmiRenderer::DestroyBackend() {
    if (surface_ != nullptr) {
        OH_Drawing_SurfaceDestroy(surface_);
        surface_ = nullptr;
        canvas_ = nullptr;
    }
    if (gpuCtx_ != nullptr) {
        OH_Drawing_GpuContextDestroy(gpuCtx_);
        gpuCtx_ = nullptr;
    }
    if (cpuCanvas_ != nullptr) {
        OH_Drawing_CanvasDestroy(cpuCanvas_);
        cpuCanvas_ = nullptr;
    }
    if (cpuBitmap_ != nullptr) {
        OH_Drawing_BitmapDestroy(cpuBitmap_);
        cpuBitmap_ = nullptr;
    }
    cpuPixels_.clear();
    if (g_fill != nullptr) {
        OH_Drawing_BrushDestroy(g_fill);
        g_fill = nullptr;
    }
    if (g_pen != nullptr) {
        OH_Drawing_PenDestroy(g_pen);
        g_pen = nullptr;
    }
}

void HmiRenderer::RenderOnce() {
    if (usingCpuBackend_.load()) {
        if (cpuCanvas_ == nullptr || cpuPixels_.empty()) {
            return;   // 后端重建失败的空窗期，别拿空指针去画
        }
        HmiState st;
        {
            std::lock_guard<std::mutex> guard(lock_);
            st = state_;
        }
        {
            // 与离线自检串行（共享文件级静态画笔/文本缓存）
            std::lock_guard<std::mutex> drawGuard(g_drawMutex);
            DrawFrame(cpuCanvas_, st);
        }
        PresentCpuCallback cb;
        {
            std::lock_guard<std::mutex> guard(lock_);
            cb = presentCpu_;
        }
        if (cb) {
            lastFlushCode_.store(cb(width_, height_, cpuPixels_.data()));
        } else {
            lastFlushCode_.store(-99);
        }
    } else {
        if (canvas_ == nullptr) {
            return;
        }
        HmiState st;
        {
            std::lock_guard<std::mutex> guard(lock_);
            st = state_;
        }
        {
            // 与离线自检串行（共享文件级静态画笔/文本缓存）
            std::lock_guard<std::mutex> drawGuard(g_drawMutex);
            DrawFrame(canvas_, st);
        }
        OH_Drawing_ErrorCode err = OH_Drawing_SurfaceFlush(surface_);
        lastFlushCode_.store(err == OH_DRAWING_SUCCESS ? 0 : (int32_t) err);
    }
    frameCount_.fetch_add(1);
}

// ---------------------------------------------------------------------------
// 离线自检：CPU 位图后端画两页，裸像素回调交给上层（不碰编码器、不起线程）
// ---------------------------------------------------------------------------

HmiRenderer::SelfCheckResult HmiRenderer::RunSelfCheck(int32_t width, int32_t height,
                                                      SelfCheckPageCallback cb) {
    // ★ 全程持有全局绘制锁：本函数会 ResetTextCache() 与 DestroyBackend()，
    //   两者都动**文件级静态资源**，必须与在线渲染线程串行（详见 g_drawMutex 注释）。
    std::lock_guard<std::mutex> drawGuard(g_drawMutex);

    SelfCheckResult r;
    r.width = (width >= 64) ? width : 1280;
    r.height = (height >= 64) ? height : 720;

    // ---- 后端：CPU 位图（自检不需要 window，也不需要 GPU）----
    // ★ 尺寸可能和上一次不同（CreateCpuBackend 用 width_/height_ 分配），先落进去
    width_ = r.width;
    height_ = r.height;

    if (!CreateCpuBackend()) {
        LOGE("自检：CPU 位图后端建不起来");
        r.failCode = 1;
        return r;
    }
    r.cpuBackendOk = 1;

    // ---- 字体集合：自检是同步调用，用完即销毁，不依赖渲染线程 ----
    OH_Drawing_FontCollection *fc = OH_Drawing_CreateSharedFontCollection();
    if (fc == nullptr) {
        LOGE("自检：字体集合创建失败");
        DestroyBackend();
        r.failCode = 2;
        return r;
    }
    fontCollection_ = fc;   // 让 Text() 走同一套缓存与排版路径

    // ---- 两页状态（用与线上一致的占位内容）----
    HmiState home{};
    home.page = HMI_PAGE_HOME;
    home.connected = 1;
    home.navi.turnType = HMI_TURN_RIGHT;
    home.navi.distanceText[0] = '3'; home.navi.distanceText[1] = '0';
    home.navi.distanceText[2] = '0'; home.navi.distanceText[3] = '\0';
    snprintf(home.navi.distanceUnit, sizeof(home.navi.distanceUnit), "%s", "m");
    snprintf(home.navi.road, sizeof(home.navi.road), "%s", "科技路");
    snprintf(home.navi.hint, sizeof(home.navi.hint), "%s", "前方路口右转进入科技路");
    snprintf(home.navi.nextHint, sizeof(home.navi.nextHint), "%s", "然后 直行 1.2 km");
    snprintf(home.audio.title, sizeof(home.audio.title), "%s", "未选择曲目");
    snprintf(home.audio.artist, sizeof(home.audio.artist), "%s", "媒体源待接入");
    home.audio.positionMs = 84000;
    home.audio.durationMs = 238000;
    home.audio.playing = 0;
    // 首页新版式（carwith_car_hmi_home.html）的顶部状态栏 / 天气 / 通勤三块。
    // 不填就走结构体默认值，出图会是"默认值"而不是真实布局 —— 验不出东西。
    snprintf(home.status.clock, sizeof(home.status.clock), "%s", "01:18");
    snprintf(home.status.carrier, sizeof(home.status.carrier), "%s", "5G");
    home.status.signalBars = 4;
    home.status.batteryPct = 78;
    home.weather.tempC = 26;
    snprintf(home.weather.condition, sizeof(home.weather.condition), "%s", "多云");
    snprintf(home.weather.city, sizeof(home.weather.city), "%s", "上海");
    snprintf(home.weather.airQuality, sizeof(home.weather.airQuality), "%s", "空气优");
    home.eta.minutes = 28;
    snprintf(home.eta.arriveAt, sizeof(home.eta.arriveAt), "%s", "09:10");
    home.navi.turnType = HMI_TURN_RIGHT;
    home.navi.distanceM = 300;
    home.navi.progress = 42;

    HmiState nav{};
    nav.page = HMI_PAGE_NAVI;
    nav.connected = 1;
    // 导航页自检必须有真实内容，否则只能验出"地图画得出来"，
    // 验不到新加的浮层（引导卡 / 进度条 / 下一步条 / FAB）。
    nav.navi.turnType = HMI_TURN_RIGHT;
    nav.navi.distanceM = 300;
    nav.navi.progress = 42;
    snprintf(nav.navi.distanceText, sizeof(nav.navi.distanceText), "%s", "300");
    snprintf(nav.navi.distanceUnit, sizeof(nav.navi.distanceUnit), "%s", "m");
    snprintf(nav.navi.road, sizeof(nav.navi.road), "%s", "科技路");
    snprintf(nav.navi.hint, sizeof(nav.navi.hint), "%s", "前方路口右转进入科技路");
    snprintf(nav.navi.nextHint, sizeof(nav.navi.nextHint), "%s", "然后 直行 1.2 km");

    struct Job {
        const HmiState *st;
        const char *name;
        double *msOut;
        int32_t *codeOut;
    };
    Job jobs[2] = {
        {&home, "home", &r.homeMs, &r.giveHomeCode},
        {&nav,  "nav",  &r.navMs,  &r.giveNavCode},
    };

    const size_t want = static_cast<size_t>(r.width) * r.height * 4;

    for (Job &job : jobs) {
        ResetTextCache();   // 每页重新排版，避免两页的字串互相挤占缓存

        auto t0 = std::chrono::steady_clock::now();
        DrawFrame(cpuCanvas_, *job.st);
        auto t1 = std::chrono::steady_clock::now();
        *job.msOut = std::chrono::duration<double, std::milli>(t1 - t0).count();

        if (!cb || cpuPixels_.size() != want) {
            *job.codeOut = cb ? -2 : 0;   // 没回调=只计时算成功；尺寸不符=失败
            if (*job.codeOut == 0) {
                LOGI("自检：%{public}s 页绘制完成 %{public}.1fms（未交付像素）",
                     job.name, *job.msOut);
            } else {
                LOGE("自检：%{public}s 页像素尺寸异常 have=%{public}zu want=%{public}zu",
                     job.name, cpuPixels_.size(), want);
            }
            continue;
        }

        cb(job.name, cpuPixels_.data(), r.width, r.height, *job.msOut);
        *job.codeOut = 0;
        LOGI("自检：%{public}s 页已交付 %{public}dx%{public}d（绘制 %{public}.1fms）",
             job.name, r.width, r.height, *job.msOut);
    }

    ResetTextCache();
    fontCollection_ = nullptr;
    OH_Drawing_DestroyFontCollection(fc);
    DestroyBackend();
    return r;
}

// ---------------------------------------------------------------------------
// 版式
// ---------------------------------------------------------------------------

void HmiRenderer::DrawFrame(OH_Drawing_Canvas *c, const HmiState &st) {
    if (c == nullptr) {
        return;
    }
    OH_Drawing_CanvasClear(c, kBg);

    if (st.page == HMI_PAGE_NAVI) {
        // 导航页：全屏地图铺底 + 浮层（参考小米 CarWith 导航版式）
        // ★ 导航页自带左侧 rail（全屏地图从 rail 右边开始），所以这里不先画 rail。
        DrawRail(c, st.page);
        DrawNaviPage(c, st);
        return;
    }

    // 首页：顶部状态栏 + 左侧 Dock + 中间导航大卡 + 右侧三卡竖排
    // （版式照 carwith_car_hmi_home.html 设计稿，2026-10-15）
    DrawHomePage(c, st);
}

// ===========================================================================
// 首页（参考 carwith_car_hmi_home.html 设计稿 · 1920×720 → 1280×720 按 2/3 折算）
//
// 设计稿骨架（自上而下 / 自左而右）：
//   顶部状态栏：左「时间」— 右「信号 5G / 电量 %」
//   主体三栏：左「竖排 Dock 6 图标」+ 中「导航大卡（flex:1）」+ 右「三张卡竖排 250px」
//
// 与旧首页（中列两卡 + 右侧地图）的区别：旧版把地图当背景铺满右侧；
// 新版地图缩成导航卡里的一条路线缩略图，右侧改成音乐/天气/通勤三卡。
// ===========================================================================

namespace {
// 首页版式常量（1280×720 基准）
constexpr double kHomePad      = 16.0;   // 屏幕内边距
constexpr double kStatusH      = 34.0;   // 顶部状态栏高
constexpr double kDockW        = 76.0;   // 左侧 Dock 宽
constexpr double kSideW        = 268.0;  // 右侧卡列宽（设计稿 250px @960 → 折算）
constexpr double kCardRadius   = 14.0;   // 卡片圆角
constexpr double kCardGapHome  = 10.0;   // 卡片间距
}  // namespace

void HmiRenderer::DrawHomePage(OH_Drawing_Canvas *c, const HmiState &st) {
    // ---- 顶部状态栏 ----
    DrawStatusBar(c, st, 0, 0, width_, kStatusH);

    // ---- 主体区起点 ----
    const double bodyY = kStatusH;
    const double bodyH = height_ - kStatusH;

    // ---- 左：竖排 Dock ----
    DrawDock(c, kHomePad, bodyY + kHomePad * 0.5, kDockW,
             bodyH - kHomePad);

    // ---- 右：三卡竖排（音乐 / 天气 / 通勤）----
    const double sideX = width_ - kHomePad - kSideW;
    const double sideTotalH = bodyH - kHomePad * 1.5;
    // 设计稿三卡等高（.side .card{flex:1}）
    const double sideCardH = (sideTotalH - kCardGapHome * 2.0) / 3.0;
    DrawMusicCard(c, st, sideX, bodyY + kHomePad * 0.5, kSideW, sideCardH);
    DrawWeatherCard(c, st, sideX, bodyY + kHomePad * 0.5 + sideCardH + kCardGapHome,
                    kSideW, sideCardH);
    DrawEtaCard(c, st, sideX, bodyY + kHomePad * 0.5 + (sideCardH + kCardGapHome) * 2.0,
                kSideW, sideCardH);

    // ---- 中：导航大卡（占满剩余宽度）----
    const double navX = kHomePad + kDockW + kCardGapHome;
    const double navW = sideX - kCardGapHome - navX;
    DrawHomeNavCard(c, st, navX, bodyY + kHomePad * 0.5, navW, sideTotalH);
}

void HmiRenderer::DrawStatusBar(OH_Drawing_Canvas *c, const HmiState &st, double x, double y,
                                double w, double h) {
    // 时间（左）
    Text(c, fontCollection_, st.status.clock, x + kHomePad + 6, y + (h - 20.0) / 2.0, 20,
         kFg1, FONT_WEIGHT_700, TEXT_ALIGN_LEFT, 200);

    // 右侧：信号 + 运营商文字 + 电量（从右往左排）
    const double cy = y + h / 2.0;
    double cur = x + w - kHomePad - 6;

    // 电量百分比文字
    char pctText[16];
    snprintf(pctText, sizeof(pctText), "%d%%", st.status.batteryPct);
    const double pctW = 58.0;
    Text(c, fontCollection_, pctText, cur - pctW, cy - 9.0, 14, kFg1, FONT_WEIGHT_500,
         TEXT_ALIGN_RIGHT, pctW);
    cur -= pctW + 8.0;

    // 电池图标（26×13 设计稿尺度）
    IconBattery(c, IconBox{cur - 30.0, cy - 8.0, 26.0}, kFg3, st.status.batteryPct);
    cur -= 30.0 + 16.0;

    // 运营商文字
    const double carW = 34.0;
    Text(c, fontCollection_, st.status.carrier, cur - carW, cy - 9.0, 14, kFg1,
         FONT_WEIGHT_500, TEXT_ALIGN_RIGHT, carW);
    cur -= carW + 6.0;

    // 信号格
    IconSignal(c, IconBox{cur - 17.0, cy - 6.5, 16.0}, kFg1, st.status.signalBars);
}

void HmiRenderer::DrawDock(OH_Drawing_Canvas *c, double x, double y, double w, double h) {
    // 底板
    FillRoundRect(c, x, y, w, h, kCardRadius, kSurface);
    StrokeRoundRect(c, x + 0.5, y + 0.5, w - 1, h - 1, kCardRadius, kBorder, 1.0);

    // 6 个图标垂直均布（设计稿 gap 12、图标 20 + 文字 12）
    const int n = 6;
    const double innerPadY = 12.0;
    const double itemH = 46.0;   // 图标 22 + 间隙 4 + 文字 14  ≈ 46
    const double span = h - innerPadY * 2.0;
    const double step = (span - itemH) / (double) (n - 1);
    const double cx = x + w / 2.0;

    const char *labels[6] = {"主页", "语音", "地图", "音乐", "通话", "更多"};

    for (int i = 0; i < n; i++) {
        const double iy = y + innerPadY + step * i;
        const bool on = (i == 0);      // 主页图标为激活态（设计稿 .di.on）
        const uint32_t col = on ? kAccent : kFg3;

        IconBox box{cx - 11.0, iy, 22.0};
        switch (i) {
            case 0: IconHome(c, box, col, 1.7); break;
            case 1: IconVoice(c, box, col, 1.7); break;
            case 2: IconMapPin(c, box, col, 1.7); break;
            case 3: IconMusic(c, box, col, 1.7); break;
            case 4: IconPhone(c, box, col, 1.7); break;
            default: IconGrid(c, box, col, 1.7); break;
        }

        Text(c, fontCollection_, labels[i], cx - 26.0, iy + 26.0, 12, col, FONT_WEIGHT_400,
             TEXT_ALIGN_CENTER, 52.0);
    }
}

void HmiRenderer::DrawHomeNavCard(OH_Drawing_Canvas *c, const HmiState &st, double x, double y,
                                  double w, double h) {
    // 卡片（设计稿 .card.nav 用 brand 色描边，表示"导航中"）
    FillRoundRect(c, x, y, w, h, kCardRadius, kSurface);
    StrokeRoundRect(c, x + 0.5, y + 0.5, w - 1, h - 1, kCardRadius, kAccent, 1.5);

    // 内容垂直居中、水平居中（设计稿 justify-content:center; align-items:center）
    const double blockH = 60.0 + 132.0 + 34.0 + 26.0 + 24.0;   // pill+图+标题+副标题+间距
    double cursor = y + (h - blockH) / 2.0;
    if (cursor < y + 12.0) {
        cursor = y + 12.0;
    }

    // ---- "导航中" pill ----
    const char *pill = "导航中";
    const double pillW = 62.0;
    const double pillH = 22.0;
    FillRoundRect(c, x + (w - pillW) / 2.0, cursor, pillW, pillH, pillH / 2.0, kAccentDim);
    Text(c, fontCollection_, pill, x + (w - pillW) / 2.0, cursor + 3.0, 12, kAccent,
         FONT_WEIGHT_500, TEXT_ALIGN_CENTER, pillW);
    cursor += pillH + 14.0;

    // ---- 路线缩略图（设计稿 280×96，等比缩到卡宽 60%）----
    const double mapW = (w * 0.62 > 320.0) ? 320.0 : w * 0.62;
    const double mapH = mapW * 96.0 / 280.0;
    const double mapX = x + (w - mapW) / 2.0;
    FillRoundRect(c, mapX, cursor, mapW, mapH, 8.0, kElevated);

    // 路线：与设计稿同形的 S 形曲线 + 途经点圆
    // ★ pts 必须能放下 N+1 个点 × 2 个 double —— 曾写成 [24] 却写入 42 个
    //   → 栈溢出 → SIGSEGV（2026-10-15 真机连崩 9 次的真凶）。
    //   常数与循环上限绑定，避免以后再错配。
    {
        constexpr int kRouteSegs = 20;
        static_assert(kRouteSegs + 1 <= 21, "pts 容量与采样点数必须匹配");
        const double u = mapW / 280.0;
        const double v = mapH / 96.0;
        double pts[(kRouteSegs + 1) * 2];
        int n = 0;
        for (int i = 0; i <= kRouteSegs; i++) {
            double t = (double) i / (double) kRouteSegs;
            double px = mapX + (t * 284.0 - 4.0) * u;
            double py = cursor + (78.0 - 46.0 * t - 18.0 * std::sin(t * M_PI)) * v;
            pts[n++] = px;
            pts[n++] = py;
        }
        Polyline(c, pts, n / 2, kAccent, 5.0);
        FillCircle(c, mapX + 128.0 * u, cursor + 32.0 * v, 6.0 * u, kAccent);
    }
    cursor += mapH + 16.0;

    // ---- 主标题：前方 300m 右转 ----
    char main[96];
    if (st.navi.distanceM >= 1000) {
        snprintf(main, sizeof(main), "前方 %.1fkm %s", st.navi.distanceM / 1000.0,
                 TurnActionText(st.navi.turnType));
    } else {
        snprintf(main, sizeof(main), "前方 %dm %s", st.navi.distanceM,
                 TurnActionText(st.navi.turnType));
    }
    Text(c, fontCollection_, main, x, cursor, 26, kFg1, FONT_WEIGHT_700, TEXT_ALIGN_CENTER, w);
    cursor += 38.0;

    // ---- 副标题：目的地 ----
    char sub[128];
    snprintf(sub, sizeof(sub), "目的地 · %s", st.navi.road);
    Text(c, fontCollection_, sub, x, cursor, 14, kFg3, FONT_WEIGHT_400, TEXT_ALIGN_CENTER, w);
}

void HmiRenderer::DrawMusicCard(OH_Drawing_Canvas *c, const HmiState &st, double x, double y,
                                double w, double h) {
    FillRoundRect(c, x, y, w, h, kCardRadius, kSurface);
    StrokeRoundRect(c, x + 0.5, y + 0.5, w - 1, h - 1, kCardRadius, kBorder, 1.0);

    const double pad = 14.0;
    const double blockH = 44.0 + 10.0 + 8.0;     // 封面行 + 进度条 + 间距
    double cursor = y + (h - blockH) / 2.0;
    if (cursor < y + pad) {
        cursor = y + pad;
    }

    // 封面
    const double cover = 44.0;
    FillRoundRect(c, x + pad, cursor, cover, cover, 8.0, kElevated);
    IconDisc(c, IconBox{x + pad + 10.0, cursor + 10.0, cover - 20.0}, kAccent);

    // 曲名 / 艺术家
    const double tx = x + pad + cover + 12.0;
    const double tmax = x + w - pad - tx;
    if (tmax > 24.0) {
        Text(c, fontCollection_, st.audio.title, tx, cursor + 2.0, 16, kFg1, FONT_WEIGHT_500,
             TEXT_ALIGN_LEFT, tmax);
        Text(c, fontCollection_, st.audio.artist, tx, cursor + 24.0, 12, kFg3, FONT_WEIGHT_400,
             TEXT_ALIGN_LEFT, tmax);
    }

    // 进度条（设计稿 42% 演示值 → 这里用真实播放比例）
    const double barY = cursor + cover + 10.0;
    const double barW = w - pad * 2.0;
    FillRoundRect(c, x + pad, barY, barW, 4.0, 2.0, kElevated);
    double ratio = 0.0;
    if (st.audio.durationMs > 0) {
        ratio = (double) st.audio.positionMs / (double) st.audio.durationMs;
    }
    if (ratio > 1.0) { ratio = 1.0; }
    if (ratio > 0.0) {
        FillRoundRect(c, x + pad, barY, barW * ratio, 4.0, 2.0, kAccent);
    }
}

void HmiRenderer::DrawWeatherCard(OH_Drawing_Canvas *c, const HmiState &st, double x, double y,
                                  double w, double h) {
    FillRoundRect(c, x, y, w, h, kCardRadius, kSurface);
    StrokeRoundRect(c, x + 0.5, y + 0.5, w - 1, h - 1, kCardRadius, kBorder, 1.0);

    const double pad = 14.0;
    const double cy = y + h / 2.0;

    // 温度（大号，左侧）
    char temp[16];
    snprintf(temp, sizeof(temp), "%d°", st.weather.tempC);
    Text(c, fontCollection_, temp, x + pad, cy - 15.0, 26, kFg1, FONT_WEIGHT_700,
         TEXT_ALIGN_LEFT, 90.0);

    // 天气 / 城市 + 空气质量
    const double tx = x + pad + 82.0;
    const double tmax = x + w - pad - tx;
    if (tmax > 24.0) {
        Text(c, fontCollection_, st.weather.condition, tx, cy - 15.0, 15, kFg1,
             FONT_WEIGHT_500, TEXT_ALIGN_LEFT, tmax);
        char sub[96];
        snprintf(sub, sizeof(sub), "%s · %s", st.weather.city, st.weather.airQuality);
        Text(c, fontCollection_, sub, tx, cy + 5.0, 12, kFg3, FONT_WEIGHT_400,
             TEXT_ALIGN_LEFT, tmax);
    }
}

void HmiRenderer::DrawEtaCard(OH_Drawing_Canvas *c, const HmiState &st, double x, double y,
                              double w, double h) {
    FillRoundRect(c, x, y, w, h, kCardRadius, kSurface);
    StrokeRoundRect(c, x + 0.5, y + 0.5, w - 1, h - 1, kCardRadius, kBorder, 1.0);

    const double pad = 14.0;
    const double cy = y + h / 2.0;

    char line1[64];
    snprintf(line1, sizeof(line1), "通勤 %d 分钟", st.eta.minutes);
    Text(c, fontCollection_, line1, x + pad, cy - 17.0, 16, kFg1, FONT_WEIGHT_500,
         TEXT_ALIGN_LEFT, w - pad * 2.0);

    char line2[64];
    snprintf(line2, sizeof(line2), "预计 %s 到达", st.eta.arriveAt);
    Text(c, fontCollection_, line2, x + pad, cy + 3.0, 12, kFg3, FONT_WEIGHT_400,
         TEXT_ALIGN_LEFT, w - pad * 2.0);
}

void HmiRenderer::DrawRail(OH_Drawing_Canvas *c, int32_t page) {
    FillRect(c, 0, 0, kRailW, height_, kBg);
    Line(c, kRailW - 0.5, 0, kRailW - 0.5, height_, kBorder, 1.0);

    const double btn = 44.0;
    const double bx = (kRailW - btn) / 2.0;   // 16
    const double top = 18.0;
    const double gap = 8.0;
    const double iconS = 26.0;

    // ★ 激活态必须跟着当前页走。
    //   曾把「首页」写死成激活 —— 结果切到导航页时左栏还亮着首页图标，
    //   页面指示与画面内容自相矛盾（2026-10-15 自检 PNG 里一眼看出）。
    const bool homeActive = (page == HMI_PAGE_HOME);
    const bool naviActive = (page == HMI_PAGE_NAVI);

    // 首页
    if (homeActive) {
        FillRoundRect(c, bx, top, btn, btn, 12, kAccentDim);
    }
    IconHome(c, IconBox{bx + (btn - iconS) / 2, top + (btn - iconS) / 2, iconS},
             homeActive ? kAccent : kFg3, 2.0);

    // 导航
    double ny = top + btn + gap;
    if (naviActive) {
        FillRoundRect(c, bx, ny, btn, btn, 12, kAccentDim);
    }
    IconNavi(c, IconBox{bx + (btn - iconS) / 2, ny + (btn - iconS) / 2, iconS},
             naviActive ? kAccent : kFg3, 2.0);

    // 设置（贴底；手机侧独有页面，车机上永不激活）
    double gy = height_ - top - btn;
    IconGear(c, IconBox{bx + (btn - iconS) / 2, gy + (btn - iconS) / 2, iconS}, kFg3, 2.0);
}

void HmiRenderer::DrawNavCard(OH_Drawing_Canvas *c, const HmiState &st, double x, double y,
                              double w, double h) {
    FillRoundRect(c, x, y, w, h, 22, kSurface);
    StrokeRoundRect(c, x + 0.5, y + 0.5, w - 1, h - 1, 22, kBorder, 1.0);

    const double ix = x + kCardPad;
    const double iw = w - kCardPad * 2.0;
    const double innerH = h - kCardPad * 2.0;

    // 内容块固定高 210，垂直居中（与视觉稿的 justify-content:center 等价）
    const double blockH = 210.0;
    double baseY = y + kCardPad + (innerH - blockH) / 2.0;

    // ---- 转向图标 ----
    const double cr = 34.0;
    double ccx = ix + cr;
    double ccy = baseY + cr;
    FillCircle(c, ccx, ccy, cr, kAccentDim);
    FillCircle(c, ccx, ccy, cr + 6, kAccentSoft);
    FillCircle(c, ccx, ccy, cr, kAccentDim);
    IconTurn(c, IconBox{ccx - 26, ccy - 26, 52}, st.navi.turnType, kAccent);

    // ---- 距离 + 路名 ----
    double tx = ix + cr * 2 + 16;
    double tmax = ix + iw - tx;
    if (tmax < 40) {
        tmax = 40;
    }
    OH_Drawing_Typography *num = GetText(fontCollection_, st.navi.distanceText, 50, kFg1,
                                         FONT_WEIGHT_700, TEXT_ALIGN_LEFT, tmax);
    Text(c, fontCollection_, st.navi.distanceText, tx, baseY - 4, 50, kFg1, FONT_WEIGHT_700,
         TEXT_ALIGN_LEFT, tmax);
    double numW = TextWidth(num);
    Text(c, fontCollection_, st.navi.distanceUnit, tx + numW + 4, baseY + 26, 24, kFg2,
         FONT_WEIGHT_500, TEXT_ALIGN_LEFT, 60);
    Text(c, fontCollection_, st.navi.road, tx, baseY + 66, 24, kFg1, FONT_WEIGHT_700,
         TEXT_ALIGN_LEFT, tmax);

    // ---- 提示 ----
    Text(c, fontCollection_, st.navi.hint, ix, baseY + 112, 19, kFg2, FONT_WEIGHT_400,
         TEXT_ALIGN_LEFT, iw);

    // ---- 下一步 ----
    Line(c, ix, baseY + 172, ix + iw, baseY + 172, kBorder, 1.0);
    IconTurn(c, IconBox{ix, baseY + 184, 22}, st.navi.turnType, kFg3);
    Text(c, fontCollection_, st.navi.nextHint, ix + 32, baseY + 186, 16, kFg3,
         FONT_WEIGHT_400, TEXT_ALIGN_LEFT, iw - 32);
}

void HmiRenderer::DrawAudioCard(OH_Drawing_Canvas *c, const HmiState &st, double x, double y,
                                double w, double h) {
    FillRoundRect(c, x, y, w, h, 22, kSurface);
    StrokeRoundRect(c, x + 0.5, y + 0.5, w - 1, h - 1, 22, kBorder, 1.0);

    const double ix = x + kCardPad;
    const double iw = w - kCardPad * 2.0;
    const double innerH = h - kCardPad * 2.0;

    // 内容块固定高 176，垂直居中
    const double blockH = 176.0;
    double baseY = y + kCardPad + (innerH - blockH) / 2.0;

    // ---- 封面 ----
    const double cover = 56.0;
    FillRoundRect(c, ix, baseY, cover, cover, 12, kElevated);
    StrokeRoundRect(c, ix + 0.5, baseY + 0.5, cover - 1, cover - 1, 12, kBorder, 1.0);
    IconDisc(c, IconBox{ix + 10, baseY + 10, cover - 20}, kAccent);

    // ---- 曲目 ----
    double tx = ix + cover + 14;
    double tmax = ix + iw - tx;
    if (tmax < 40) {
        tmax = 40;
    }
    Text(c, fontCollection_, st.audio.title, tx, baseY + 2, 22, kFg1, FONT_WEIGHT_700,
         TEXT_ALIGN_LEFT, tmax);
    Text(c, fontCollection_, st.audio.artist, tx, baseY + 30, 15, kFg2, FONT_WEIGHT_400,
         TEXT_ALIGN_LEFT, tmax);

    // ---- 进度条 ----
    double barY = baseY + 72;
    FillRoundRect(c, ix, barY, iw, 5, 2.5, kElevated);
    double ratio = 0;
    if (st.audio.durationMs > 0) {
        ratio = (double) st.audio.positionMs / (double) st.audio.durationMs;
    }
    if (ratio < 0) {
        ratio = 0;
    }
    if (ratio > 1) {
        ratio = 1;
    }
    if (ratio > 0) {
        FillRoundRect(c, ix, barY, iw * ratio, 5, 2.5, kAccent);
    }

    // ---- 时间 ----
    auto fmt = [](int32_t ms, char *out, size_t n) {
        if (ms < 0) {
            ms = 0;
        }
        int total = ms / 1000;
        snprintf(out, n, "%d:%02d", total / 60, total % 60);
    };
    char cur[16] = "0:00";
    char dur[16] = "0:00";
    fmt(st.audio.positionMs, cur, sizeof(cur));
    fmt(st.audio.durationMs, dur, sizeof(dur));
    Text(c, fontCollection_, cur, ix, barY + 14, 13, kFg3, FONT_WEIGHT_400, TEXT_ALIGN_LEFT, 80);
    Text(c, fontCollection_, dur, ix + iw - 80, barY + 14, 13, kFg3, FONT_WEIGHT_400,
         TEXT_ALIGN_RIGHT, 80);

    // ---- 控制按钮（居中：上一个 / 播放暂停 / 下一个）----
    const double bigD = 56.0;
    const double smallD = 44.0;
    const double ctrlGap = 22.0;
    double totalW = smallD + ctrlGap + bigD + ctrlGap + smallD;
    double cx0 = ix + (iw - totalW) / 2.0;
    double ctrlY = baseY + 104;

    FillRoundRect(c, cx0, ctrlY + (bigD - smallD) / 2, smallD, smallD, smallD / 2, kElevated);
    StrokeRoundRect(c, cx0 + 0.5, ctrlY + (bigD - smallD) / 2 + 0.5, smallD - 1, smallD - 1,
                    smallD / 2, kBorder, 1.0);
    IconPrev(c, IconBox{cx0 + 10, ctrlY + (bigD - smallD) / 2 + 10, smallD - 20}, kFg1);

    double bx = cx0 + smallD + ctrlGap;
    FillRoundRect(c, bx, ctrlY, bigD, bigD, bigD / 2, kAccent);
    if (st.audio.playing != 0) {
        IconPause(c, IconBox{bx + 14, ctrlY + 14, bigD - 28}, 0xFF06131F);
    } else {
        IconPlay(c, IconBox{bx + 14, ctrlY + 14, bigD - 28}, 0xFF06131F);
    }

    double nx = bx + bigD + ctrlGap;
    FillRoundRect(c, nx, ctrlY + (bigD - smallD) / 2, smallD, smallD, smallD / 2, kElevated);
    StrokeRoundRect(c, nx + 0.5, ctrlY + (bigD - smallD) / 2 + 0.5, smallD - 1, smallD - 1,
                    smallD / 2, kBorder, 1.0);
    IconNext(c, IconBox{nx + 10, ctrlY + (bigD - smallD) / 2 + 10, smallD - 20}, kFg1);
}

void HmiRenderer::DrawMap(OH_Drawing_Canvas *c, double x, double y, double w, double h) {
    FillRect(c, x, y, w, h, kMapBg);

    // 次级路网
    for (double gy = y + 96; gy < y + h; gy += 118) {
        Line(c, x, gy, x + w, gy, kMapMinor, 2.0);
    }
    for (double gx = x + 170; gx < x + w; gx += 150) {
        Line(c, gx, y, gx, y + h, kMapMinor, 2.0);
    }
    // 主干道
    Line(c, x, y + h / 2, x + w, y + h / 2, kMapMajor, 5.0);
    Line(c, x + w / 2, y, x + w / 2, y + h, kMapMajor, 5.0);

    // 已规划路线：按地图区尺寸等比铺（908 宽与 1204 宽都好看）
    double u = w / 908.0;
    double v = h / 720.0;
    const double pts[] = {
        x + 60 * u,        y + 640 * v,
        x + 230 * u,       y + 640 * v,
        x + 230 * u,       y + 470 * v,
        x + 430 * u,       y + 470 * v,
        x + 430 * u,       y + 300 * v,
        x + 700 * u,       y + 300 * v,
        x + 700 * u,       y + 166 * v,
        x + 860 * u,       y + 166 * v,
    };
    Polyline(c, pts, 8, kRouteDim, 20.0);
    Polyline(c, pts, 8, kAccent, 8.0);

    // 终点
    FillCircle(c, x + 860 * u, y + 166 * v, 20 * u, kAccentSoft);
    FillCircle(c, x + 860 * u, y + 166 * v, 9 * u, kAccent);

    // 车辆位置
    FillCircle(c, x + 430 * u, y + 470 * v, 24 * u, kAccentSoft);
    FillCircle(c, x + 430 * u, y + 470 * v, 11 * u, kFg1);
    StrokeCircle(c, x + 430 * u, y + 470 * v, 11 * u, kAccent, 4.0 * u);
}

// ===========================================================================
// 导航页（参考小米 CarWith）
//
// ## 版式来源（逆向自 com.miui.carlink404.apk）
//
// CarWith 的导航卡（`res/layout/nav_progress_view_1a.xml` + `LinearProgressView.java`）
// 有三个标志性特征，这里逐一照搬：
//   1. ★ **进度条铺满整张卡当背景**（不是卡下面一条细线）——
//      `LinearProgressView` 是 match_parent 铺满整卡，`onDraw()` 只有两行：
//      `drawRect(0,0,w,h)` 画底 + `drawRect(0,0,w*progress/100,h)` 画进度。
//   2. 转向图标在左：宽 = 卡宽 **24%**、1:1、垂直居中
//      （`app:layout_constraintWidth_percent="0.24"`）。
//   3. 文字在右，字号按**卡宽比例**缩放（`NavProgressView1A.g(int width)`）：
//      distance = 0.12w / unit = 0.07w / action = 0.071w / address = 0.06w。
//
// ## 骨架来源
//
// 卡片**浮在地图上**、而不是把屏幕切成两栏 —— 这是 Google Android Auto 导航
// 模板的官方要求（全屏基础地图 + 路线卡片 + 操作条 + FAB），
// 见 `design/nav-hmi/RESEARCH.md`。
//
// ## 深色主题适配
//
// CarWith 的进度色 `nav_progress_color(#d8e6ff)` 是**浅蓝配浅色卡**；
// 本项目是深色主题，取等价的「强调色暗调」`kAccentDim` 当进度填充。
// ===========================================================================

void HmiRenderer::DrawNaviPage(OH_Drawing_Canvas *c, const HmiState &st) {
    // ---- 底：全屏地图（不是"一块区域"）----
    DrawMap(c, kRailW, 0, width_ - kRailW, height_);

    const double cardX = kRailW + 20.0;
    const double cardW = 460.0;

    // ---- 浮层 1：左上导航引导卡 ----
    const double cardH = 196.0;
    DrawNaviGuideCard(c, st, cardX, 20.0, cardW, cardH);

    // ---- 浮层 2：左下"下一步"提示条 ----
    const double nextH = 68.0;
    DrawNaviNextBar(c, st, cardX, height_ - 20.0 - nextH, cardW, nextH);

    // ---- 浮层 3：右下"回到当前位置"FAB ----
    DrawNaviFab(c, width_ - 52.0, height_ - 52.0, 32.0);
}

void HmiRenderer::DrawNaviGuideCard(OH_Drawing_Canvas *c, const HmiState &st, double x, double y,
                                    double w, double h) {
    const double rad = 20.0;

    // ---- 1) 卡片底 ----
    FillRoundRect(c, x, y, w, h, rad, kSurface);

    // ---- 2) ★ 进度条铺满整张卡当背景（CarWith 的标志性做法）----
    //   不裁圆角会把卡的圆角盖成方角，所以先 Clip 再填矩形。
    int32_t prog = st.navi.progress;
    if (prog > 100) {
        prog = 100;
    }
    if (prog > 0) {
        ClipRoundRectStart(c, x, y, w, h, rad);
        FillRect(c, x, y, w * prog / 100.0, h, kAccentDim);
        ClipEnd(c);
    }

    // ---- 3) 描边画在进度之上，避免进度条吃掉边框 ----
    StrokeRoundRect(c, x + 0.5, y + 0.5, w - 1, h - 1, rad, kBorder, 1.0);

    // ---- 4) 左侧转向图标：24% 卡宽、1:1、垂直居中 ----
    double iconS = w * 0.24;
    const double iconMax = h - 28.0;
    if (iconS > iconMax) {
        iconS = iconMax;
    }
    const double icx = x + w * 0.05 + iconS / 2.0;
    const double icy = y + h / 2.0;
    FillCircle(c, icx, icy, iconS * 0.50, kAccentSoft);
    FillCircle(c, icx, icy, iconS * 0.43, kAccentDim);
    IconTurn(c, IconBox{icx - iconS * 0.26, icy - iconS * 0.26, iconS * 0.52},
             st.navi.turnType, kAccent);

    // ---- 5) 右侧文字：字号按卡宽比例（抄 CarWith NavProgressView1A.g()）----
    const double tx = x + w * 0.33;
    const double tmax = x + w - 18.0 - tx;
    const double distSize = w * 0.12;    // 300
    const double unitSize = w * 0.07;    // m
    const double actSize = w * 0.071;    // 右转
    const double roadSize = w * 0.06;    // 科技路

    // 第一行：距离（大号粗体）+ 单位 + 动作
    const double line1Y = y + 30.0;
    Text(c, fontCollection_, st.navi.distanceText, tx, line1Y, distSize, kFg1,
         FONT_WEIGHT_700, TEXT_ALIGN_LEFT, tmax);
    const double dw = TextWidth(GetText(fontCollection_, st.navi.distanceText, distSize, kFg1,
                                        FONT_WEIGHT_700, TEXT_ALIGN_LEFT, tmax));
    const double ux = tx + dw + 8.0;
    Text(c, fontCollection_, st.navi.distanceUnit, ux, line1Y + distSize * 0.42, unitSize, kFg2,
         FONT_WEIGHT_500, TEXT_ALIGN_LEFT, 80);
    const double uw = TextWidth(GetText(fontCollection_, st.navi.distanceUnit, unitSize, kFg2,
                                        FONT_WEIGHT_500, TEXT_ALIGN_LEFT, 80));
    Text(c, fontCollection_, TurnActionText(st.navi.turnType), ux + uw + 10.0,
         line1Y + distSize * 0.42, actSize, kFg3, FONT_WEIGHT_500, TEXT_ALIGN_LEFT, 120);

    // 第二行：路名
    const double line2Y = line1Y + distSize * 1.30;
    Text(c, fontCollection_, st.navi.road, tx, line2Y, roadSize, kFg1, FONT_WEIGHT_700,
         TEXT_ALIGN_LEFT, tmax);

    // 第三行：提示（更暗更小，与 CarWith 的 address 层级一致）
    const double line3Y = line2Y + roadSize * 1.45;
    Text(c, fontCollection_, st.navi.hint, tx, line3Y, roadSize * 0.82, kFg2, FONT_WEIGHT_400,
         TEXT_ALIGN_LEFT, tmax);
}

void HmiRenderer::DrawNaviNextBar(OH_Drawing_Canvas *c, const HmiState &st, double x, double y,
                                  double w, double h) {
    FillRoundRect(c, x, y, w, h, 16, kElevated);
    StrokeRoundRect(c, x + 0.5, y + 0.5, w - 1, h - 1, 16, kBorder, 1.0);

    const double iconS = 30.0;
    IconTurn(c, IconBox{x + 20.0, y + (h - iconS) / 2.0, iconS}, st.navi.turnType, kFg3);

    const double tx = x + 20.0 + iconS + 14.0;
    const double tmax = x + w - 18.0 - tx;
    Text(c, fontCollection_, "下一步", tx, y + 10.0, 16, kFg3, FONT_WEIGHT_400,
         TEXT_ALIGN_LEFT, tmax);
    Text(c, fontCollection_, st.navi.nextHint, tx, y + 33.0, 20, kFg1, FONT_WEIGHT_500,
         TEXT_ALIGN_LEFT, tmax);
}

void HmiRenderer::DrawNaviFab(OH_Drawing_Canvas *c, double cx, double cy, double r) {
    // 深色半透明圆底
    FillCircle(c, cx, cy, r, 0xE61E2430);
    StrokeCircle(c, cx, cy, r - 0.5, kBorder, 1.0);

    // "回到当前位置"图标：准星（圆环 + 四向刻度 + 中心点）
    const uint32_t col = kFg1;
    StrokeCircle(c, cx, cy, r * 0.46, col, 2.2);
    FillCircle(c, cx, cy, r * 0.16, kAccent);
    const double t0 = r * 0.46;
    const double t1 = r * 0.72;
    Line(c, cx, cy - t0, cx, cy - t1, col, 2.2);
    Line(c, cx, cy + t0, cx, cy + t1, col, 2.2);
    Line(c, cx - t0, cy, cx - t1, cy, col, 2.2);
    Line(c, cx + t0, cy, cx + t1, cy, col, 2.2);
}

} // namespace carhi
