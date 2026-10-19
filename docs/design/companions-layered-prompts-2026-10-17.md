# 分层局部编辑提示词 · 2026-10-17

使用内置 imagegen；源图为当前项目中已确认角色 PNG，透明背景。输出为当前项目 `entry/src/main/resources/base/media/companions_*_plate.png` 与 `companions_*_head.png`。

## 去除五官，保持角色画布

Use case: precise-object-edit. This is a technical animation clean-plate edit, not character design. Preserve EXACTLY the attached image's canvas, full silhouette, pose, size, position, head shape, ears, paws, outlines, colors, internal gradients, blush cheeks and transparent background. CHANGE ONLY: erase the facial eyebrows, both eyes including their highlights/cream eye whites, nose and mouth, replacing these small face marks with uninterrupted matching original face surface. For the BEAR keep the large cream muzzle patch intact, just remove dark nose and mouth from that patch. For the BUNNY keep the white face and pink cheeks intact. Do not erase ear interior or paw marks. Do NOT resize, zoom, crop, rotate or recenter anything. Do not invent a different mascot, no added features or shadows. Output the identical image with a blank face ready for independent facial layers, preserving existing alpha transparency. No shadows, glows, halos, backdrop or new artifacts.

## bubu_head

Use case: precise-object-edit. Technical animation layer separation. Use the attached blank-face character plate as the exact editing target. Preserve its EXACT canvas, size, position, all unmentioned pixels, transparency and empty margins. Do not recenter or zoom. REMOVE ONLY the specified detachable parts, reconstructing a small clean continuation of the head/body behind them in the same colors and outline. Do not add a face or any features. No glow, shadow or backdrop. Keep the SAME framing so the removed original parts can be overlaid at their ORIGINAL coordinates and restore the original character. Detach only the RIGHT round ear and the RIGHT bottom front paw (viewer right). Remove them from this head layer. Keep the LEFT ear, LEFT paw, forehead tuft, round cheek/head shape, cream muzzle patch and blush unchanged. Smoothly close the head contour behind the missing right ear and paw. Leave transparent empty area where detached parts were. Do NOT crop canvas.

## xiuxiu_head

Use case: precise-object-edit. Technical animation layer separation. Use the attached blank-face character plate as the exact editing target. Preserve its EXACT canvas, size, position, all unmentioned pixels, transparency and empty margins. Do not recenter or zoom. REMOVE ONLY the specified detachable parts, reconstructing a small clean continuation of the head/body behind them in the same colors and outline. Do not add a face or any features. No glow, shadow or backdrop. Keep the SAME framing so the removed original parts can be overlaid at their ORIGINAL coordinates and restore the original character. Detach BOTH ears (viewer left folded ear and tall right ear), and detach the LEFT bottom front paw (viewer left). This head layer must contain only the blank-faced rounded bunny head/cheeks, blush and existing RIGHT paw. Close the top of head smoothly where the ears attached and the bottom cheek where left paw attached, without changing the head's size or position. Leave transparent empty area for the detached ears and left paw. No face, no recentering, do NOT crop canvas.

## 移除剩余爪子，供 near/far 独立装配

Technical animation clean-plate correction. EDIT TARGET is this exact blank-face character head. Keep EXACTLY the same canvas dimensions, head size/position, ears (if still present), blush, outlines, cream muzzle (bear), interior coloring and alpha. Change ONLY: remove the remaining bottom front paw entirely, closing the head's lower outline smoothly behind it. Result must have NO PAWS. Do not add a face. Do not crop/zoom/recenter/rotate. This head will be layered behind independent paw parts at their original coordinates, so framing must stay identical. Genuinely transparent background; no glow/shadow/ground rectangle.

五官为代码原生 SVG，并非生成工具导出的纯矢量；装配坐标见 CompanionRig.ets。

