export interface PushAccount { project_id: string; key_id: string; private_key: string; sub_account: string; }
type Environment = Record<string, string | undefined>;
const ACCOUNT = 'FORTWO_PUSH_SERVICE_ACCOUNT';
const COUNT = ACCOUNT + '_PARTS';
const MAX_PARTS = 32;

function accountKey(name: string): boolean { return name === ACCOUNT || name.startsWith(ACCOUNT + '_'); }

/** Only fixed errors escape this module; JSON parser errors can contain private key fragments. */
export function readPushAccount(env: Environment = process.env): PushAccount {
  try {
    const count = env[COUNT]; const full = env[ACCOUNT];
    const keys = Object.keys(env).filter(name => name.startsWith(ACCOUNT + '_') && env[name] !== undefined);
    let json: string;
    if (count !== undefined) {
      if (!/^[1-9][0-9]?$/.test(count) || Number(count) > MAX_PARTS || (full !== undefined && full !== '')) throw new Error();
      const total = Number(count); const expected = new Set<string>([COUNT]); const parts: string[] = [];
      for (let i = 1; i <= total; i++) {
        const name = ACCOUNT + '_' + i; expected.add(name); const part = env[name];
        if (typeof part !== 'string' || part.length < 1 || part.length > 512) throw new Error();
        parts.push(part);
      }
      if (keys.some(name => !expected.has(name))) throw new Error();
      json = parts.join('');
    } else {
      if (keys.length !== 0 || typeof full !== 'string' || full.length === 0) throw new Error();
      json = full;
    }
    if (Buffer.byteLength(json, 'utf8') > 16384) throw new Error();
    const value: unknown = JSON.parse(json);
    if (!value || typeof value !== 'object' || Array.isArray(value)) throw new Error();
    const account = value as PushAccount;
    if (typeof account.project_id !== 'string' || !/^[0-9]+$/.test(account.project_id)
      || typeof account.key_id !== 'string' || !account.key_id.trim()
      || typeof account.sub_account !== 'string' || !account.sub_account.trim()
      || typeof account.private_key !== 'string' || !account.private_key.includes('-----BEGIN PRIVATE KEY-----')
      || !account.private_key.includes('-----END PRIVATE KEY-----')) throw new Error();
    return account;
  } catch { throw new Error('PUSH_CONFIG_INVALID'); }
}

/** Context is platform-owned. Replace the account as a unit on reused worker instances. */
export function installPushAccountEnvironment(source: Environment): void {
  const names = Object.keys(source).filter(accountKey);
  if (names.length === 0) return;
  for (const name of Object.keys(process.env).filter(accountKey)) delete process.env[name];
  for (const name of names) if (typeof source[name] === 'string') process.env[name] = source[name];
}
