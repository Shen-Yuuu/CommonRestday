export declare class PlanCasProbe {
  getClassName(): string;
  getFieldTypeMap(): Map<string, string>;
  getPrimaryKeyList(): string[];
  getIndexList(): never[];
  getEncryptedFieldList(): string[];
  getId(): string;
  setId(value: string): void;
  getVersion(): number;
  setVersion(value: number): void;
  getState(): string;
  setState(value: string): void;
  getCreatedAt(): number;
  setCreatedAt(value: number): void;
}
