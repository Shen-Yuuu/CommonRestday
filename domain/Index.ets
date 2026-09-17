/**
 * domain HAR 对外导出。
 * 本模块为纯逻辑层：禁止 import 任何 @kit.*（CI/lint 约束），保证可本地单测。
 */

export * from './src/main/ets/model/Types';
export * from './src/main/ets/utils/TimeUtil';
export * from './src/main/ets/expand/CycleExpander';
export * from './src/main/ets/expand/CourseExpander';
export * from './src/main/ets/buffer/AvailabilityBuilder';
export * from './src/main/ets/merge/IntervalOps';
export * from './src/main/ets/classify/WindowClassifier';
export * from './src/main/ets/engine/CommonFreeEngine';
export * from './src/main/ets/conflict/PlanConflict';
export * from './src/main/ets/parse/CourseTextParser';
export * from './src/main/ets/snapshot/SnapshotCodec';
export * from './src/main/ets/snapshot/SnapshotBuilder';
