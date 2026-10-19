/** Production image-import methods with deterministic platform adapters; no device accuracy claim. */
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const root = path.resolve(__dirname, '../..');
const ts = require('D:/local/DevEcoStudio/tools/hvigor/hvigor/node_modules/typescript');
const compile = text => ts.transpileModule(text, {compilerOptions:{target:ts.ScriptTarget.ES2020,module:ts.ModuleKind.CommonJS}}).outputText;
const read = file => fs.readFileSync(path.join(root,file),'utf8');
const parser = {};
new Function('exports', compile(read('domain/src/main/ets/parse/CourseTextParser.ets')))(parser);
const routes = {};
new Function('exports','require',compile(read('entry/src/main/ets/model/RouteParams.ets')))(routes,()=>({OWNER_ME:'ME',OWNER_PARTNER:'PARTNER'}));
const source = read('entry/src/main/ets/pages/OcrCourse.ets');
const logic = source.slice(source.indexOf('  @State owner:'),source.indexOf('  build()')).replace(/@State /g,'');
const exportsPage = {};
let state;
let pickerResult;
let recognition;
let pendingSave;
const params = {owner:'PARTNER',source:'album'};
const router = {getParams:()=>params,back:()=>{state.backs++}};
const pixel = {release:async()=>{state.pixelRelease++}};
const imageSource = {getImageInfo:async()=>({size:{width:8192,height:4096}}),createPixelMap:async options=>{state.options=options;return pixel},release:async()=>{state.sourceRelease++}};
const fileIo = {OpenMode:{READ_ONLY:1},open:async uri=>{assert.equal(uri,'selected-photo');state.open++;return {fd:77}},close:async()=>{state.close++}};
const image = {PixelMapFormat:{RGBA_8888:3},createImageSource:fd=>{assert.equal(fd,77);return imageSource}};
const textRecognition = {init:async()=>true,recognizeText:async()=>{state.recognizeCalls++;return recognition()},release:async()=>{state.modelRelease++}};
const photoAccessHelper = {PhotoViewMIMETypes:{IMAGE_TYPE:1},PhotoViewPicker:class {select(){state.pickers++;return pickerResult()}}};
const service = {importCourses:async(list,owner)=>{state.imports.push({list,owner});return pendingSave()}};
const util = {generateRandomUUID:()=> 'uuid-'+(++state.uuid)};
new Function('exports','OWNER_ME','router','ownerFromParams','courseImageSource','photoAccessHelper','fileIo','image','textRecognition','parseCourseImageText','toCourse','ScheduleCommandService','util','Logger','toastCommand','appToast','MAX_IMAGE_EDGE','TAG',compile('export class ImagePage {\n'+logic+'\n}'))(exportsPage,'ME',router,routes.ownerFromParams,routes.courseImageSource,photoAccessHelper,fileIo,image,textRecognition,parser.parseCourseImageText,parser.toCourse,service,util,{warn:()=>{}},()=>{},()=>{},4096,'test');
function deferred(){let resolve;const promise=new Promise(r=>{resolve=r});return {promise,resolve}}
function reset(){state={pickers:0,open:0,pixelRelease:0,sourceRelease:0,close:0,modelRelease:0,recognizeCalls:0,imports:[],uuid:0,backs:0};pickerResult=async()=>({photoUris:['selected-photo']});recognition=async()=>({value:'高数 周一 第1-2节 1-16周 单周'});pendingSave=async()=>({ok:false});const page=new exportsPage.ImagePage();page.aboutToAppear();return page}
(async()=>{
  let page=reset();await page.pickImage();assert.equal(page.owner,'PARTNER');assert.equal(page.parsed[0].ok,true);assert.equal(page.confirmed,false);assert.deepEqual(state.options.desiredSize,{width:4096,height:2048});assert.equal(state.options.desiredPixelFormat,3);assert.deepEqual([state.pixelRelease,state.sourceRelease,state.close,state.modelRelease],[1,1,1,1]);await page.saveParsed();assert.equal(state.imports.length,0,'unconfirmed OCR must never persist');
  page.confirmed=true;const save=deferred();pendingSave=()=>save.promise;const first=page.saveParsed();await page.saveParsed();assert.equal(state.imports.length,1,'repeated save must share the in-flight exclusion');assert.equal(state.imports[0].owner,'PARTNER');save.resolve({ok:false});await first;assert.equal(page.parsed.length,1);assert.equal(page.saving,false);assert.equal(state.backs,0,'failed save retains draft and route');
  page=reset();pickerResult=async()=>({photoUris:[]});await page.pickImage();assert.equal(state.open,0);assert.equal(page.busy,false);assert.equal(state.imports.length,0);
  page=reset();recognition=async()=>{throw Error('offline service failure')};await page.pickImage();assert.equal(page.parsed.length,0);assert.equal(page.busy,false);assert.match(page.statusText,/本次识别未完成/);assert.deepEqual([state.pixelRelease,state.sourceRelease,state.close,state.modelRelease],[1,1,1,1]);
  page=reset();const ocr=deferred();recognition=()=>ocr.promise;const running=page.pickImage();for(let n=0;n<20&&!state.recognizeCalls;n++)await Promise.resolve();assert.equal(state.recognizeCalls,1);page.aboutToDisappear();ocr.resolve({value:'高数 周一 第1-2节 1-16周'});await running;assert.equal(page.ocrText,'');assert.equal(page.parsed.length,0);assert.equal(state.close,1,'late results still release their resources');
  page=reset();await page.pickImage();page.confirmed=true;pendingSave=async()=>({ok:true});await page.saveParsed();assert.equal(state.backs,1);assert.equal(state.imports[0].list[0].parity,1);
  page=reset();const pick=deferred();pickerResult=()=>pick.promise;const selecting=page.pickImage();await page.pickImage();assert.equal(state.pickers,1);pick.resolve({photoUris:[]});await selecting;
  assert.deepEqual(routes.courseImageParam('PARTNER','album'),{owner:'PARTNER',source:'album'});assert.equal(routes.courseImageSource({owner:'PARTNER',source:'untrusted'}),'');
  console.log('course-image-import: PASS (production methods: URI fd, bounded RGBA decode, resource cleanup, cancel/failure/late return, confirmation, duplicate save and owner preservation; NOT OCR accuracy)');
})().catch(e=>{console.error(e);process.exitCode=1});
