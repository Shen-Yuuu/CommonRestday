import { actor, guarded, digest } from './identity';
import { parseCommand } from './protocol';
import * as service from './service';
import { dispatchEvent } from './push';
import { enqueueWake } from './wake';
import * as bootstrap from './bootstrap';

/** Separate secure channel. Public handlers never depend on framework-bound `this`. */
export class DatePlan {
  async publishLink(accessToken: string, pairId: string, route: string, offer: string): Promise<Record<string, Object>> {
    return guarded(async () => bootstrap.publishLink(await actor(accessToken), pairId, route, offer), 'publishLink');
  }
  async discoverLink(accessToken: string, route: string): Promise<Record<string, Object>> {
    return guarded(async () => bootstrap.discoverLink(await actor(accessToken), route), 'discoverLink');
  }
  async createPair(accessToken: string, requestId: string, publicKey: string, projectionVersion: number, link = ''): Promise<Record<string, Object>> {
    return guarded(async () => service.createPair(await actor(accessToken), requestId, publicKey, projectionVersion, link), 'createPair');
  }
  async joinPair(accessToken: string, inviteCode: string, publicKey: string, projectionVersion: number, link = ''): Promise<Record<string, Object>> {
    return guarded(async () => service.joinPair(await actor(accessToken), inviteCode, publicKey, projectionVersion, link), 'joinPair');
  }
  async confirmPair(accessToken: string, pairId: string, confirmSecret: string): Promise<Record<string, Object>> {
    return guarded(async () => service.confirmPair(await actor(accessToken), pairId, confirmSecret), 'confirmPair');
  }
  async pairStatus(accessToken: string, pairId: string): Promise<Record<string, Object>> {
    return guarded(async () => service.pairStatus(await actor(accessToken), pairId), 'pairStatus');
  }
  async capabilities(accessToken: string, pairId: string): Promise<Record<string, Object>> {
    return guarded(async () => service.pairStatus(await actor(accessToken), pairId), 'capabilities');
  }
  async mutate(accessToken: string, commandJson: string): Promise<Record<string, Object>> {
    return guarded(async context => {
      context.stage = 'auth'; const who = await actor(accessToken, context);
      context.stage = 'parseCommand'; const command = parseCommand(commandJson);
      const result = await service.mutate(who, command, context);
      // Notification failure cannot make a committed operation look unknown or roll it back.
      const started = Date.now(); let path = 'NO_EVENT';
      try {
        const plan = result.plan as { stateVersion?: number } | undefined;
        if (result.code === 'OK' && Number.isSafeInteger(plan?.stateVersion)) {
          const eventId = digest([command.pairId, command.planId, plan!.stateVersion!]);
          if (await enqueueWake(eventId)) path = 'DURABLE_WAKE';
          else { path = 'SYNC_FALLBACK'; await dispatchEvent(eventId); }
        }
      } catch { path = 'OUTBOX_DEFERRED'; /* Never turn commit into RESULT_UNKNOWN. */ }
      try {
        const message = JSON.stringify({ tag: 'FORTWO_PLAN_NOTIFY_PATH', build: '2026-10-14-wake1',
          path, elapsedMs: Math.max(0, Date.now() - started) });
        const runtime = globalThis as typeof globalThis & { logger?: { info(message: string): void } };
        if (runtime.logger?.info) runtime.logger.info(message); else console.info(message);
      } catch { /* Diagnostic only; no payloads/IDs/provider errors. */ }
      return result;
    }, 'mutate');
  }
  async read(accessToken: string, pairId: string): Promise<Record<string, Object>> {
    return guarded(async () => service.read(await actor(accessToken), pairId), 'read');
  }
  async readChanges(accessToken: string, pairId: string, cursor: number): Promise<Record<string, Object>> {
    return guarded(async () => service.readChanges(await actor(accessToken), pairId, cursor), 'readChanges');
  }
  async acknowledge(accessToken: string, pairId: string, cursor: number, candidates: string): Promise<Record<string, Object>> {
    return guarded(async () => service.acknowledge(await actor(accessToken), pairId, cursor, candidates) as Promise<Record<string, Object>>,
      'acknowledge');
  }
  async requestStatus(accessToken: string, commandJson: string): Promise<Record<string, Object>> {
    return guarded(async () => service.requestStatus(await actor(accessToken), parseCommand(commandJson)), 'requestStatus');
  }
  async closeRequest(accessToken: string, commandJson: string): Promise<Record<string, Object>> {
    return guarded(async () => service.closeRequest(await actor(accessToken), parseCommand(commandJson)), 'closeRequest');
  }
  async cleanupCreate(accessToken: string, flowId: string): Promise<Record<string, Object>> {
    return guarded(async () => service.cleanupCreate(await actor(accessToken), flowId), 'cleanupCreate');
  }
  async registerPush(accessToken: string, pairId: string, pushToken: string, enabled: boolean): Promise<Record<string, Object>> {
    return guarded(async () => service.registerPush(await actor(accessToken), pairId, pushToken, enabled), 'registerPush');
  }
  async unpair(accessToken: string, pairId: string): Promise<Record<string, Object>> {
    return guarded(async () => service.unpair(await actor(accessToken), pairId), 'unpair');
  }
}
