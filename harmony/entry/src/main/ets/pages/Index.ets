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
import { ALL_CHANNELS, ChannelDef } from '../protocol/Constants';
import { CarLifeRuntime } from '../entryability/EntryAbility';

/** SectionCard 未传内容时的占位（@BuilderParam 需要默认值） */
@Builder
function EmptyContent() {
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
  @State statusMessage: string = '点击「启动服务」开始监听车机连接';

  private engine: CarLifeEngine | null = null;
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
  }

  aboutToDisappear(): void {
    if (this.logTimer !== -1) {
      clearInterval(this.logTimer);
      this.logTimer = -1;
    }
    this.engine?.stop();
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

  /** 启动 / 停止 */
  private async toggleService(): Promise<void> {
    if (this.running) {
      this.engine?.stop();
      this.engine = null;
      this.running = false;
      this.stateText = '未连接';
      this.statusMessage = '服务已停止';
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
      }
    };

    this.engine = new CarLifeEngine(listener);
    try {
      await this.engine.start();
      this.running = true;
      this.statusMessage = '已监听全部端口，请让车机发起连接';
    } catch (e) {
      const err = e as Error;
      this.statusMessage = `启动失败: ${err.message}`;
      CarLifeRuntime.addLog(`启动失败: ${err.message}`);
      this.engine = null;
    }
  }
}
