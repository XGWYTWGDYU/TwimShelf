# 新图标设计稿

方向 C：白墙上的洞洞板，左上方柔和的暖光洒下，板上钉着几张纸（不用照片）。用 Blender 脚本建模、Cycles 渲染。

- `pegboard_blender.py`：场景脚本。`Blender -b --factory-startup -P icon-design/pegboard_blender.py -- dark 160`（`light` 或 `dark`，后面是采样数），结果是 `out/c3d-<mode>-art.png`（铺满的方图，iOS 用的就是这种）
- `frame.py`：把方图套进 `icon.png` 的格式（Mac 圆角加透明边距）：`python3 icon-design/frame.py c3d-light c3d-dark`
- `preview.html` / `render.sh`：大图、iOS、Android 圆形裁切、64/32/16 像素在浅色和深色背景上，结果在 `out/preview.png`

已定：
- 深色模式：黑板配白卡；浅色模式：白板配黑卡
- 不要窗户的影子，光从左上方柔和地洒下
- 板子横向（不是 1:1），在画面里占大部分

- 相机正对板子（从侧面看，透视会让板子显得歪），厚度感靠光和投影

选定后，把 `out/` 里的 PNG 换成仓库根目录的 `icon.png`，任何一次构建（`scripts/apply.py`）都会重新生成各平台的图标。浅色、深色两套图标要按系统模式切换，图标生成流程还得另外支持。
