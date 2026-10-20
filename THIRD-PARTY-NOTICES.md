# 第三方开源声明（Third-Party Notices）

本模块（Cirno Reclaim Hybrid）以 GPL-3.0-only 发布，见 `LICENSE`。
运行期还包含下列 MIT 许可的第三方代码片段，按 MIT 要求在此保留版权与许可声明。

---

## liquid-glass（液态玻璃位移滤镜）

- 上游项目：https://github.com/nikdelvin/liquid-glass
- 作者：Nikita Stadnik（Nik Delvin）
- 许可证：MIT
- 使用位置：`webroot/app.js` 中的 `lgDisplacementMap()` 与 `lgDisplacementFilter()`
  （移植自上游 `src/utils/liquidGlass.ts` 的 `getDisplacementMap` / `getDisplacementFilter`），
  以及 `webroot/style.css` 里 `:root.liquid-on` 相关样式（为本项目重新编写）。
- 改动说明：上游把滤镜用在卡片上（`backdrop-filter` + 大尺寸位移贴图）；
  本项目把它用在底栏滑块上，尺寸/强度按滑块高度重新计算，并在
  `backdrop-filter: url()` 不可用时自动降级为不启用（`liquid-on` 类不会加上）。

```
MIT License

Copyright (c) 2025 Nikita Stadnik

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```
