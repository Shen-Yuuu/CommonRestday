# 原造型统一素材 · 2026-10-17

用户确认三组互动校对稿“造型一致，按这版继续细化”。允许表情、动作和身体变化，不更换角色脸型与特征。
制作方式：内置 imagegen，identity-preserve 编辑，透明背景。
参考：`docs/prototype/assets/companions-identity-expressions-review-2026-10-17.png`。

## 已接入素材

| 资源（entry/src/main/resources/base/media） | 正式消费者 | 显示 / 解码尺寸 |
|---|---|---|
| bubu_peek.png | ConfirmDialog | 86×68vp / 344×264px |
| xiuxiu_peek.png | WindowDetailSheet | 96×88vp / 384×358px |
| xiuxiu_sleep.png | StatePanel.SleepBunny | 76×76vp / 304×293px |

显示均为 Contain，禁止拖动，不在图片矩形上叠阴影；旧 SVG 不再被这三处消费，但保留文件可回退。
页头仍用已选双角色原图，未用三组校对图作跳帧切换。

## 后续分层阶段

这三份仍是完整静态图，用于确认框/计划弹窗/空状态。随后已另行完成页头的位图身体 + 八套 SVG 五官 + 耳爪分层与四段叙事，见 `companions-layer-map-2026-10-17.md`；它们没有被冒充成可独立装配的图层。音效/触觉未加入。

## 完整提示词

### bubu

Use case: identity-preserve. Input image is the USER APPROVED character model study, not loose style inspiration. Make a finished clean app illustration asset of ONE character only. Preserve exactly the approved character's head/cheek proportions, ear shapes, warm thick contour, simple dark brown facial drawing, blush with two diagonal marks, white/apricot/pink palette and soft interior coloring. Expressions and actions CAN change. Do not redesign the character. NO fur spikes, realistic/glitter eyes, new accessories, 3D realism. CRITICAL OUTPUT: genuinely transparent alpha. No glow, no aura, no shadow, no ground plane, no blur outside outline, no colored mist, no white scribble strip or ragged cut edge. Use a fully closed clean smooth bottom silhouette, the complete outline must stay inside the canvas with 8% transparent margin. No text. Flat clean 2D sticker-like contour with subtle original shading INSIDE only. Draw only BUBU the APRICOT BEAR, isolated from the white rabbit. Preserve approved rounded ears, one small simple forehead tuft, cream muzzle, small cocoa nose and original curved smile, two diagonal blush marks per cheek. Calm and slightly curious expression, simple original crescent/dot eyes (not realistic). The bear peeks up with TWO small rounded apricot paws at its lower edge, head taking most of illustration. Complete the hidden cheek in the same original shape, not a perfectly symmetric circle. NO bunny. Wide bust suitable for confirmation dialog.

### xiuxiu_peek

Use case: identity-preserve. Input image is the USER APPROVED character model study, not loose style inspiration. Make a finished clean app illustration asset of ONE character only. Preserve exactly the approved character's head/cheek proportions, ear shapes, warm thick contour, simple dark brown facial drawing, blush with two diagonal marks, white/apricot/pink palette and soft interior coloring. Expressions and actions CAN change. Do not redesign the character. NO fur spikes, realistic/glitter eyes, new accessories, 3D realism. CRITICAL OUTPUT: genuinely transparent alpha. No glow, no aura, no shadow, no ground plane, no blur outside outline, no colored mist, no white scribble strip or ragged cut edge. Use a fully closed clean smooth bottom silhouette, the complete outline must stay inside the canvas with 8% transparent margin. No text. Flat clean 2D sticker-like contour with subtle original shading INSIDE only. Draw only XIUXIU the WHITE BUNNY, isolated from the bear. Its defining broad flopped LEFT ear and tall RIGHT ear MUST keep the approved shapes and proportions. Original broad rounded cheek silhouette and tiny cocoa nose, simple brown eyes, pink ears and two diagonal blush marks per cheek. Gentle playful expression, one eye softly winking and small open smiling mouth. Two tiny white rounded front paws are visible at the lower edge. NO bear. Head-and-paws bust, not a standing rabbit. Keep the bottom outline closed and clean (not a horizontal cut).

### xiuxiu_sleep

Use case: identity-preserve. Input image is the USER APPROVED character model study, not loose style inspiration. Make a finished clean app illustration asset of ONE character only. Preserve exactly the approved character's head/cheek proportions, ear shapes, warm thick contour, simple dark brown facial drawing, blush with two diagonal marks, white/apricot/pink palette and soft interior coloring. Expressions and actions CAN change. Do not redesign the character. NO fur spikes, realistic/glitter eyes, new accessories, 3D realism. CRITICAL OUTPUT: genuinely transparent alpha. No glow, no aura, no shadow, no ground plane, no blur outside outline, no colored mist, no white scribble strip or ragged cut edge. Use a fully closed clean smooth bottom silhouette, the complete outline must stay inside the canvas with 8% transparent margin. No text. Flat clean 2D sticker-like contour with subtle original shading INSIDE only. Draw only XIUXIU the SAME WHITE BUNNY from the approved study, in a quietly sleeping pose. Keep the exact same broad flopped LEFT ear and tall RIGHT ear, rounded wide cheek head, pink inner ears and original tiny cocoa nose/mouth drawing and two diagonal blush marks. Eyes softly CLOSED as simple brown curved eyelids; a small relaxed smile. Add a VERY small rounded seated white body with two tiny rounded feet and tiny front paws resting in lap; head is 70% of height, ears unchanged. Do not replace the flopped ear with two upright ears, do not change it into a different bunny. No Z letters, hearts or other decorations. Entire closed silhouette visible.

