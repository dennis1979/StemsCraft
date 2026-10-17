# 更新紀錄

本檔記錄 StemCraft 每個版本的變更。版本號遵循 [語意化版本（Semantic Versioning）](https://semver.org/lang/zh-TW/)。
英文版：[CHANGELOG.md](CHANGELOG.md)。

## [1.0.0] - 2026-10-17

第一個公開版本。

**系統需求：** Apple 晶片（Apple silicon，M1 以上）的 Mac，macOS 14（Sonoma）以上。不支援 Intel 架構的 Mac。

### 新增
- 使用 HTDemucs 將歌曲分離為四軌（鼓、貝斯、人聲、其他），透過 ONNX Runtime 在本機執行。安裝完成後不需要網路連線。
- 分軌播放器：每一軌都可以靜音、獨奏、調整音量，並支援變速不變調（time-stretch）。
- 偵測速度（BPM）與拍點格線。
- 可直接將音訊檔拖曳到視窗中，或開啟檔案匯入。可以排隊處理多首歌曲，依序分析。
- 將分離出的各軌匯出為 WAV 檔。
- 保存已分析歌曲的資料庫，重新開啟同一首歌曲時可以立即載入。預設資料夾為 `~/Music/StemsCraft`，可在設定中更改。
