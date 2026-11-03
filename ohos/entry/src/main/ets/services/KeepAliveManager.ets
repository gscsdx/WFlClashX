import { common, wantAgent } from '@kit.AbilityKit';
import backgroundTaskManager from '@ohos.resourceschedule.backgroundTaskManager';
import { notificationManager } from '@kit.NotificationKit';
import { hilog } from '@kit.PerformanceAnalysisKit';

const TAG: string = 'FlClashX-KeepAlive';

/**
 * UI-process continuous-task holder.
 *
 * startBackgroundRunning may only be called from a UIAbility context: the
 * stage-model gate rejects extension contexts with 401 (Permission denied),
 * which is exactly what happened when ClashVpnExtensionAbility tried to hold
 * the task itself. The long-running dataTransfer task is therefore held HERE,
 * in the main process, while the actual VPN work lives in the extension.
 *
 * A DATA_TRANSFER continuous task is reaped by the system after ~10 minutes
 * unless it observes BOTH live progress updates and real traffic. Publish a
 * download-template live-view notification every minute — Huawei's documented
 * workaround for VPN apps (developer forum topic 0204188825713661027).
 */
export class KeepAliveManager {
  private static instance: KeepAliveManager | null = null;

  static get(): KeepAliveManager {
    if (KeepAliveManager.instance === null) {
      KeepAliveManager.instance = new KeepAliveManager();
    }
    return KeepAliveManager.instance;
  }

  private running: boolean = false;
  /** Continuous-task notification id returned by startBackgroundRunning. */
  private notificationId: number = 0;
  /** Minute cadence timer for the live-view progress ping. */
  private progressTimer: number = -1;
  private progress: number = 0;
  private title: string = 'FlClashX';

  setTitle(title: string): void {
    if (title !== '') {
      this.title = title;
    }
  }

  isRunning(): boolean {
    return this.running;
  }

  /** Request the continuous task; idempotent while already running. */
  async enable(context: common.UIAbilityContext): Promise<void> {
    if (this.running) {
      return;
    }
    // actionType/actionFlags (not the deprecated operationType/wantAgentFlags
    // spellings): the HarmonyOS 5.x runtime rejects the agent produced from
    // the deprecated fields with 16000151 "Invalid wantAgent object".
    const info: wantAgent.WantAgentInfo = {
      wants: [{
        bundleName: context.abilityInfo.bundleName,
        abilityName: context.abilityInfo.name
      }],
      actionType: wantAgent.OperationType.START_ABILITY,
      requestCode: 0,
      actionFlags: [wantAgent.WantAgentFlags.UPDATE_PRESENT_FLAG]
    };
    const agent = await wantAgent.getWantAgent(info);
    // The string[] overload (API 12+) returns the continuous-task notification
    // id that publishProgress() needs; requires "backgroundModes":
    // ["dataTransfer"] on THIS UIAbility in module.json5.
    const res = await backgroundTaskManager.startBackgroundRunning(
      context, ['dataTransfer'], agent);
    this.notificationId = res.notificationId;
    this.running = true;
    hilog.info(0x0000, TAG, 'continuous task started id=%{public}d', this.notificationId);
    this.progressTimer = setInterval(() => this.publishProgress(), 60 * 1000);
  }

  /** Release the continuous task and its timer; safe to call any time. */
  disable(context: common.UIAbilityContext): void {
    if (this.progressTimer !== -1) {
      clearInterval(this.progressTimer);
      this.progressTimer = -1;
    }
    if (!this.running) {
      return;
    }
    this.running = false;
    backgroundTaskManager.stopBackgroundRunning(context).catch((e: object) => {
      hilog.warn(0x0000, TAG, 'stop continuous task: %{public}s', JSON.stringify(e));
    });
  }

  /** Live-view progress ping that keeps the DATA_TRANSFER task alive. */
  private publishProgress(): void {
    if (!this.running) {
      return;
    }
    this.progress = (this.progress + 1) % 100;
    const template: notificationManager.NotificationTemplate = {
      name: 'downloadTemplate',
      data: {
        title: this.title,
        fileName: 'VPN 隧道',
        progressValue: this.progress
      }
    };
    const request: notificationManager.NotificationRequest = {
      id: this.notificationId,
      content: {
        notificationContentType:
          notificationManager.ContentType.NOTIFICATION_CONTENT_SYSTEM_LIVE_VIEW,
        systemLiveView: {
          // typeCode 8 = upload/download live view (only supported value).
          typeCode: 8,
          title: this.title,
          text: 'VPN 运行中'
        }
      },
      notificationSlotType: notificationManager.SlotType.LIVE_VIEW,
      template: template
    };
    notificationManager.publish(request).catch((e: object) => {
      hilog.warn(0x0000, TAG, 'progress publish: %{public}s', JSON.stringify(e));
    });
  }
}
