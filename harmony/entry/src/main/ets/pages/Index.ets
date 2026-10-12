/**
 * CarLife 手机端主界面
 *
 * 功能：
 *   - 启动/停止服务
 *   - 显示 7 通道连接状态
 *   - 显示握手状态
 *   - 显示推流统计（帧率/码率/总帧数）
 *   - 滚动日志
 */

import { CarLifeEngine, EngineListener } from '../core/CarLifeEngine';
import { HandshakeState, stateName } from '../core/StateMachine';
import { BackgroundKeeper } from '../core/BackgroundKeeper';
import { CaptureGate, CaptureGrantState } from '../core/CaptureGate';
import { UsbProbe, UsbProbeResult, UsbLinkKind } from '../core/UsbProbe';
import { ALL_CHANNELS, ChannelDef } from '../protocol/Constants';
import { CarLifeRuntime } from '../entryability/EntryAbility';

/** SectionCard 未传内容时的占位（@BuilderParam 需要默认值） */
@Builder
function EmptyContent() {
}

/**
 * 引擎单例（模块级）。
 *
 * 为什么提到模块级：本应用要在**长时任务下持续后台运行**，
 * 而页面（Index）在切后台/重建时会被销毁重建。若把引擎挂在页面实例上，
 * 每次重建都会重新 start() → 与车机的连接被反复重建 → 表现为周期性掉线。
 * 提到模块级后，引擎生命周期独立于页面，页面只负责「订阅状态 + 手动停止」。
 */
export class EngineHolder {
  private static inst: CarLifeEngine | null = null;
  private static listenerRef: EngineListener | null = null;

  static get engine(): CarLifeEngine | null {
    return EngineHolder.inst;
  }

  static get isRunning(): boolean {
    return EngineHolder.inst !== null;
  }

  /** 启动（幂等）。若已有引擎则仅切换 UI 回调，不重启底层服务。 */
  static async start(listener: EngineListener): Promise<boolean> {
    EngineHolder.listenerRef = listener;
    if (EngineHolder.inst !== null) {
      return false;   // 未新建，调用方据此判断
    }
    const eng = new CarLifeEngine(listener);
    await eng.start();
    EngineHolder.inst = eng;
    return true;      // 新建成功
  }

  /** 用户主动停止。 */
  static stop(): void {
    EngineHolder.inst?.stop();
    EngineHolder.inst = null;
    EngineHolder.listenerRef = null;
  }
}

/** 统一的卡片容器 */
@Component
struct SectionCard {
  @Prop title: string = '';
  @BuilderParam content: () => void = EmptyContent;

  build() {
    Column({ space: 8 }) {
      Text(this.title)
        .fontSize(13)
        .fontWeight(FontWeight.Medium)
        .fontColor('#8B949E')
        .width('100%')
      this.content()
    }
    .width('100%')
    .padding(12)
    .backgroundColor('#161B22')
    .borderRadius(10)
    .alignItems(HorizontalAlign.Start)
  }
}

@Entry
@Component
struct Index {
  @State running: boolean = false;
  @State stateText: string = '未连接';
  @State logs: string[] = [];
  @State channelConnected: boolean[] = [];
  @State fps: number = 0;
  @State kbps: number = 0;
  @State frameTotal: number = 0;
  @State statusMessage: string = '正在自动启动监听服务...';
  /** 录屏授权提示（弹框由系统控制，这里只做文字引导） */
  @State grantHint: string = '';
  /** 授权受阻：需要在界面上显示「重新授权」按钮 */
  @State grantBlocked: boolean = false;
  /** USB 诊断：最近一次结论文案 */
  @State usbSummary: string = '尚未诊断（插好 USB 后点「诊断 USB」）';
  /** USB 诊断：网络接口列表 */
  @State usbNetIfaces: string[] = [];
  /** USB 诊断：链路形态 */
  @State usbKind: number = UsbLinkKind.NONE;

  private scroller: Scroller = new Scroller();
  private logTimer: number = -1;

  aboutToAppear(): void {
    const states: boolean[] = [];
    for (let i = 0; i < ALL_CHANNELS.length; i++) {
      states.push(false);
    }
    this.channelConnected = states;
    // 轮询日志（CarLifeRuntime.logs 是普通数组，不是 @State，无法直接触发刷新）
    this.logTimer = setInterval(() => {
      if (CarLifeRuntime.logs.length !== this.logs.length) {
        this.logs = CarLifeRuntime.logs.slice();
        this.scroller.scrollEdge(Edge.Bottom);
      }
    }, 300);

    // 默认开启：进入首页即自动启动监听服务（无需用户手动点击）。
    // 服务启动后立刻申请长时任务，保证切后台/熄屏时监听与保活不被冻结。
    this.startService().catch((e: Error) => {
      CarLifeRuntime.addLog(`自动启动失败: ${e.message}`);
    });
  }

  aboutToDisappear(): void {
    // 只清理 UI 侧的日志轮询定时器。
    //
    // ⚠ 不要在这里 engine.stop()：
    //   本应用的目标是「申请长时任务后持续后台运行」，而页面消失（切后台、
    //   跳转其他页面）恰恰是后台运行的常态。若在此停服务，会导致
    //   每次切后台都断开与车机的连接、回来后重新握手 —— 表现为周期性掉线。
    //   引擎的停止改由用户点「停止服务」，或由 EntryAbility.onDestroy 统一处理。
    if (this.logTimer !== -1) {
      clearInterval(this.logTimer);
      this.logTimer = -1;
    }
  }

  build() {
    Column() {
      // ---------- 标题栏 ----------
      Row() {
        Text('CarHi')
          .fontSize(22)
          .fontWeight(FontWeight.Bold)
          .fontColor('#E6EDF3')
        Blank()
        Text(this.running ? '运行中' : '已停止')
          .fontSize(13)
          .fontColor(this.running ? '#3FB950' : '#8B949E')
          .backgroundColor(this.running ? '#1F3A24' : '#21262D')
          .padding({ left: 10, right: 10, top: 4, bottom: 4 })
          .borderRadius(12)
      }
      .width('100%')
      .padding({ left: 16, right: 16, top: 12, bottom: 12 })

      Scroll() {
        Column({ space: 12 }) {
          // ---------- 握手状态 ----------
          SectionCard({ title: '握手状态' }) {
            Column({ space: 6 }) {
              Text(this.stateText)
                .fontSize(16)
                .fontColor('#58A6FF')
                .width('100%')
              Text(this.statusMessage)
                .fontSize(12)
                .fontColor('#8B949E')
                .width('100%')
            }
            .width('100%')
            .alignItems(HorizontalAlign.Start)
          }

          // ---------- 推流统计 ----------
          SectionCard({ title: '推流统计' }) {
            Row() {
              this.StatItem('帧率', `${this.fps} fps`)
              this.StatItem('码率', `${this.kbps} kbps`)
              this.StatItem('总帧数', `${this.frameTotal}`)
            }
            .width('100%')
          }

          // ---------- 后台保活状态 ----------
          SectionCard({ title: '后台保活' }) {
            Column({ space: 6 }) {
              Row() {
                Circle({ width: 8, height: 8 })
                  .fill(BackgroundKeeper.isActive ? '#3FB950' : '#484F58')
                Text(BackgroundKeeper.isActive
                  ? `长时任务生效中（${BackgroundKeeper.mode}）`
                  : '未申请长时任务')
                  .fontSize(13)
                  .fontColor(BackgroundKeeper.isActive ? '#3FB950' : '#8B949E')
                  .margin({ left: 8 })
              }
              .width('100%')

              Text('使用说明：在手机上打开系统"驾驶模式"或导航，本应用保持运行即可把整个手机画面推给车机。切到后台时请勿在本应用的任务卡片上划掉它。')
                .fontSize(11)
                .fontColor('#6E7681')
                .width('100%')
            }
            .width('100%')
            .alignItems(HorizontalAlign.Start)
          }

          // ---------- 录屏授权 ----------
          // 说明：手机端系统强制每次启动采集都弹授权框，应用无法"记住授权"。
          // 这里能做的只是——把弹框时机压到系统下限 + 弹框前明确引导。
          SectionCard({ title: '录屏授权' }) {
            Column({ space: 8 }) {
              Row() {
                Circle({ width: 8, height: 8 })
                  .fill(CaptureGate.current === CaptureGrantState.GRANTED ? '#3FB950'
                    : (this.grantBlocked ? '#F85149' : '#D29922'))
                Text(CaptureGate.label)
                  .fontSize(13)
                  .fontColor(CaptureGate.current === CaptureGrantState.GRANTED ? '#3FB950'
                    : (this.grantBlocked ? '#F85149' : '#D29922'))
                  .margin({ left: 8 })
              }
              .width('100%')

              if (this.grantHint !== '') {
                Text(this.grantHint)
                  .fontSize(12)
                  .fontColor(this.grantBlocked ? '#F85149' : '#D29922')
                  .width('100%')
              }

              if (this.grantBlocked) {
                Button('重新授权')
                  .fontSize(14)
                  .height(34)
                  .width('100%')
                  .backgroundColor('#1F6FEB')
                  .onClick(() => {
                    EngineHolder.engine?.retryCapture();
                  })
              }

              Text('系统限制：鸿蒙手机端录屏授权为强制弹框，应用无法永久记住。'
                + '本应用已做到只在必要时弹一次，并在弹框前提示；拒绝后不会反复弹。')
                .fontSize(11)
                .fontColor('#6E7681')
                .width('100%')
            }
            .width('100%')
            .alignItems(HorizontalAlign.Start)
          }

          // ---------- USB 直连诊断 ----------
          // 目的：USB 直连下手机端「要不要改代码」取决于车机走哪条路——
          //   路 A（CDC-ECM/RNDIS 网络模式）：手机拿到 USB 网卡，现有 0.0.0.0 监听直接可用，零改造
          //   路 B（AOA 配件模式）：无 IP 网络，需新增 fd 字节流传输层
          // 插好 USB、车机启动 CarLife 后点「诊断」，即可立刻分辨。
          SectionCard({ title: 'USB 直连诊断' }) {
            Column({ space: 8 }) {
              Row() {
                Circle({ width: 8, height: 8 })
                  .fill(this.usbKind === UsbLinkKind.IP_NETWORK ? '#3FB950'
                    : (this.usbKind === UsbLinkKind.ACCESSORY ? '#D29922' : '#484F58'))
                Text(this.usbKind === UsbLinkKind.IP_NETWORK ? 'USB 网络模式（零改造）'
                  : (this.usbKind === UsbLinkKind.ACCESSORY ? 'USB 配件模式（需改造）'
                    : (this.usbKind === UsbLinkKind.BOTH ? '两种特征并存' : '未检测到 USB 会话')))
                  .fontSize(13)
                  .fontColor(this.usbKind === UsbLinkKind.IP_NETWORK ? '#3FB950'
                    : (this.usbKind === UsbLinkKind.ACCESSORY ? '#D29922' : '#8B949E'))
                  .margin({ left: 8 })
              }
              .width('100%')

              Text(this.usbSummary)
                .fontSize(12)
                .fontColor('#8B949E')
                .width('100%')

              if (this.usbNetIfaces.length > 0) {
                Text(`网络接口：${this.usbNetIfaces.join('  |  ')}`)
                  .fontSize(11)
                  .fontColor('#6E7681')
                  .width('100%')
              }

              Button('诊断 USB')
                .fontSize(14)
                .height(34)
                .width('100%')
                .backgroundColor('#21262D')
                .onClick(() => {
                  this.runUsbProbe();
                })

              Text('用法：用数据线连上车机 → 在车机上启动 CarLife → 回到本页点「诊断 USB」。'
                + '若显示「USB 网络模式」，说明现有代码已能直接接收车机连接，无需改造。')
                .fontSize(11)
                .fontColor('#6E7681')
                .width('100%')
            }
            .width('100%')
            .alignItems(HorizontalAlign.Start)
          }

          // ---------- 通道状态 ----------
          SectionCard({ title: '通道状态' }) {
            Column({ space: 4 }) {
              ForEach(ALL_CHANNELS, (def: ChannelDef, idx: number) => {
                Row() {
                  Circle({ width: 8, height: 8 })
                    .fill(this.channelConnected[idx] ? '#3FB950' : '#484F58')
                  Text(`通道 ${def.channel}  :${def.port}`)
                    .fontSize(13)
                    .fontColor('#C9D1D9')
                    .margin({ left: 8 })
                  Blank()
                  Text(def.desc)
                    .fontSize(12)
                    .fontColor('#6E7681')
                }
                .width('100%')
                .height(26)
              }, (def: ChannelDef) => `${def.channel}`)
            }
            .width('100%')
          }

          // ---------- 操作按钮 ----------
          Row({ space: 12 }) {
            Button(this.running ? '停止服务' : '启动服务')
              .layoutWeight(1)
              .height(44)
              .backgroundColor(this.running ? '#DA3633' : '#238636')
              .fontColor('#FFFFFF')
              .onClick(() => {
                this.toggleService();
              })
          }
          .width('100%')

          // ---------- 日志 ----------
          SectionCard({ title: '运行日志' }) {
            Scroll(this.scroller) {
              Column({ space: 2 }) {
                ForEach(this.logs, (line: string) => {
                  Text(line)
                    .fontSize(11)
                    .fontColor('#8B949E')
                    .fontFamily('monospace')
                    .width('100%')
                    .textAlign(TextAlign.Start)
                }, (line: string, idx: number) => `${idx}_${line}`)
              }
              .width('100%')
              .alignItems(HorizontalAlign.Start)
            }
            .height(200)
            .width('100%')
            .scrollBar(BarState.Off)
          }
        }
        .width('100%')
        .padding({ left: 16, right: 16, bottom: 24 })
      }
      .layoutWeight(1)
      .scrollBar(BarState.Off)
    }
    .width('100%')
    .height('100%')
    .backgroundColor('#0D1117')
  }

  @Builder
  StatItem(label: string, value: string) {
    Column({ space: 4 }) {
      Text(value)
        .fontSize(17)
        .fontWeight(FontWeight.Medium)
        .fontColor('#E6EDF3')
      Text(label)
        .fontSize(11)
        .fontColor('#6E7681')
    }
    .layoutWeight(1)
  }

  /** 启动 / 停止（按钮入口） */
  private async toggleService(): Promise<void> {
    if (this.running) {
      this.stopService();
      return;
    }
    await this.startService();
  }

  /** 执行一次 USB 诊断（只读，不改变连接） */
  private async runUsbProbe(): Promise<void> {
    CarLifeRuntime.addLog('开始 USB 诊断...');
    try {
      const r: UsbProbeResult = await UsbProbe.probe();
      const lines: string[] = UsbProbe.format(r);
      for (let i = 0; i < lines.length; i++) {
        CarLifeRuntime.addLog(lines[i]);
      }
      this.usbSummary = r.summary;
      this.usbKind = r.kind;
      this.usbNetIfaces = r.netIfaces;
    } catch (e) {
      const err = e as Error;
      this.usbSummary = `诊断失败: ${err.message}`;
      CarLifeRuntime.addLog(`USB 诊断失败: ${err.message}`);
    }
  }

  /** 停止服务（用户主动点击，会真正停掉底层引擎） */
  private stopService(): void {
    EngineHolder.stop();
    this.running = false;
    this.stateText = '未连接';
    this.statusMessage = '服务已停止';
    CarLifeRuntime.addLog('服务已停止（可再次点击「启动服务」恢复）');
  }

  /** 启动服务（进入首页自动调用，也可由按钮手动触发） */
  private async startService(): Promise<void> {
    if (EngineHolder.isRunning) {
      // 引擎已在后台存活（例如页面被重建后回来）——只把 UI 状态同步过来，
      // 绝不重启底层服务，否则会与车机反复重新握手。
      this.running = true;
      this.statusMessage = '已监听全部端口，请让车机发起连接';
      return;
    }
    this.statusMessage = '正在启动...';

    const listener: EngineListener = {
      onStateChange: (state: HandshakeState) => {
        this.stateText = stateName(state);
      },
      onLog: (text: string) => {
        CarLifeRuntime.addLog(text);
      },
      onChannelChange: (channel: number, connected: boolean) => {
        const next = this.channelConnected.slice();
        const idx = ALL_CHANNELS.findIndex((d: ChannelDef) => d.channel === channel);
        if (idx >= 0 && idx < next.length) {
          next[idx] = connected;
          this.channelConnected = next;
        }
      },
      onStats: (fps: number, kbps: number, frames: number) => {
        this.fps = fps;
        this.kbps = kbps;
        this.frameTotal = frames;
      },
      onGrantPrompt: () => {
        // 系统录屏授权框即将弹出，UI 给出明确引导（弹框本身无法被应用控制）
        this.grantHint = '请在系统弹窗中点「允许」以开始录屏推流';
        this.grantBlocked = false;
      },
      onCaptureBlocked: (reason: string) => {
        // 用户拒绝 / 尝试用尽 —— 亮出「重新授权」入口
        this.grantHint = `${reason}，请点下方「重新授权」`;
        this.grantBlocked = true;
      }
    };

    try {
      await EngineHolder.start(listener);
      this.running = true;
      this.statusMessage = '已监听全部端口，请让车机发起连接';
    } catch (e) {
      const err = e as Error;
      this.statusMessage = `启动失败: ${err.message}`;
      CarLifeRuntime.addLog(`启动失败: ${err.message}`);
    }
  }
}
