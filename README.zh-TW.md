# StemsCraft

[English](README.md) | **繁體中文**

StemsCraft 是一個 macOS 原生 App,可以在本機把歌曲分離成**鼓 / 貝斯 / 人聲 / 其他**四軌,並讓你自由播放:靜音、獨奏、各軌音量、變速,以及自動偵測的拍點格線。所有運算都在本機完成,不會上傳任何音訊。

## 功能

- 透過 ONNX Runtime 在本機執行 4 軌分離(HTDemucs),設定完成後不需要網路
- 分軌播放器:每一軌可靜音、獨奏、調整音量,並支援變速
- 速度(BPM)與拍點格線偵測
- 可拖放或開啟音訊檔,多首歌會排入佇列逐一分析
- 可將分離後的各軌匯出為 WAV
- 已分析的歌曲會存入資料庫,再次開啟同一首歌是即時的(預設資料夾為 `~/Music/StemsCraft`,可在設定中更改)

## 安裝(預先建置的 App)

1. 從 [Releases](../../releases) 頁面下載 `StemsCraft-1.0.0.dmg`,把 **StemsCraft** 拖到「應用程式」資料夾。模型已包含在 App 內。
2. 這個 App 只有臨時簽章,沒有經過 Apple 公證,所以 macOS 第一次開啟時會阻擋。請到 **系統設定 → 隱私權與安全性**,按一下 **仍要打開**;或執行:
   ```sh
   xattr -dr com.apple.quarantine /Applications/StemsCraft.app
   ```
3. 需要 macOS 14 或更新版本。發佈版本是在 Apple 晶片的 Mac 上建置的。

## 使用方式

1. 將音訊檔拖到視窗上(或使用新增按鈕)開始。第一次處理一首歌需要幾十秒到幾分鐘,視歌曲長度和你的 Mac 而定。
2. 完成後會得到「原始」加上「鼓 / 貝斯 / 其他 / 人聲」共五條軌道。使用 **M** / **S** 靜音或獨奏,並用滑桿調整音量。
3. 分析結果會被快取,再次開啟同一個檔案是即時的。使用匯出按鈕可以把各軌存成 WAV。

如果空白視窗顯示 **Model not found**,表示 App 找不到 ONNX 模型,請參考下方的「從原始碼建置」。

## 從原始碼建置

模型檔不在這個 repo 裡(約 170 MB,是從 Demucs 權重衍生的),所以需要你自己產生一次。

**你需要:** macOS 14 以上的 Mac、Xcode 15 以上(Swift 5.9 以上),以及 Python 3.10 以上(作者使用的是 3.14)。第一次匯出模型時,Demucs 會下載預訓練的 HTDemucs 權重,所以需要網路連線。

```sh
git clone git@github.com:dennis1979/StemsCraft.git StemsCraft
cd StemsCraft

# 1. 產生 ONNX 模型
python3 -m venv .venv
source .venv/bin/activate
pip install -r requirements.txt
python spike2_split_middle.py
```

腳本執行完會顯示 `PASS`,並在 repo 根目錄產生 `spike2_split_middle.onnx` 和 `spike2_split_middle.onnx.data`(兩個檔案要放在一起)。腳本也會用 PyTorch 做自我檢查,最差情況的 SNR 達到 50 dB 以上即為通過。

```sh
# 2. 建置、打包並簽章 App(release 模式,臨時簽章)
./package.sh

# 3. 執行
open dist/StemsCraft.app
```

`package.sh` 會產生 `dist/StemsCraft.app` 和 `dist/StemsCraft-<版本號>.dmg`(版本號取自 `VERSION` 檔),App 內已包含模型、字型與授權檔案。

### 命令列分離

不開 App 也可以在終端機分離檔案:

```sh
swift build --package-path app -c release
app/.build/release/StemsCLI <song.mp3|wav|...> spike2_split_middle.onnx <output-dir>
```

會在輸出資料夾寫入 `drums.wav`、`bass.wav`、`other.wav`、`vocals.wav`(16-bit、44.1 kHz、立體聲)。

### App 如何尋找模型

依序為:App 套件內部、環境變數 `STEMS_MODEL`、App 偏好設定中儲存的路徑。

### 疑難排解

- `swift build` 失敗:安裝 Xcode 命令列工具(`xcode-select --install`),並確認 `xcodebuild -version` 顯示 15 以上。
- 匯出腳本無法安裝或匯入 `demucs`:請使用乾淨的虛擬環境,並使用較新的 Python。
- macOS 顯示 App「已損毀」或「無法打開」:請參考上方「安裝」中的 `xattr` 指令。

## 為 macOS 調整模型的過程

HTDemucs 無法整體匯出成 ONNX,而且 Apple 平台沒有 PyTorch 執行環境,所以 StemsCraft 把模型拆開:訊號處理的部分用 Swift 在本機執行,只有實數的神經網路核心跑在 ONNX Runtime 上。

### 背景:先前嘗試的做法

StemsCraft 源自一個網頁版原型。在做原生 App 之前,我們在 Apple Silicon 上試過三種分離引擎:

| 引擎 | 執行位置 | 結果 |
| --- | --- | --- |
| 透過 ONNX Runtime Web 執行的 MDX-Net(有 WebGPU 時用 GPU,否則用多執行緒 WASM) | 瀏覽器 | 可以運作,但聲音偏悶:模型只處理最低的 2,048 個頻率格,高頻被截掉(人聲約到 14.7 kHz、其他約 11 kHz、貝斯約 5.5 kHz)。比 Demucs 慢(4 分 35 秒的歌,WebGPU 需要 1 分 05 秒)。只保留作為對照。 |
| 使用 Apple GPU(MPS)的 PyTorch Demucs `htdemucs` | 本機 Python 伺服器 | 聲音較乾淨,速度也較快(同一首 4 分 35 秒的歌只需 29 秒)。被選為參考模型。 |
| HPSS(中位數濾波,不用模型) | 瀏覽器 | 沒有授權疑慮,但結果不理想,尤其是大鼓偏薄。只作為對照。 |

Core ML 從來沒有試過。做原生 App 的目的是免去另外啟動 Python 伺服器:使用者只需要一個獨立的 App,就能在本機執行 Demucs 模型。

### 為什麼不整體匯出模型

`spike1_export_compare.py` 嘗試直接匯出單一個 HTDemucs 子模型(`htdemucs`,7.8 秒片段,輸入為 44.1 kHz 立體聲,輸出 4 軌)。它在三個地方失敗:

1. 舊版 `torch.onnx.export` 拒絕這個模型,錯誤訊息是 *"STFT does not currently support complex types"*(STFT 不支援複數型別)。
2. 新版 dynamo 匯出器在複數運算上出錯(對複數 STFT 輸出做 `aten.pad` 時)。即使是最簡單的 STFT 加 iSTFT 來回測試,匯出的圖也會被 ONNX Runtime 拒絕載入。
3. 匯出的圖無法在 ONNX Runtime 載入:`ScatterND` 收到 `int32` 索引,但 ONNX 規範要求 `int64`。

嘗試過的修正方法(保留在 repo 中作為實驗紀錄):

- `spike1_export_compare.py` 在執行時修補 Demucs(不修改 Demucs 套件中的任何檔案):移除 `pad1d` 中依賴資料值的 assert,並把 `HTDemucs._ispec` 中對複數張量的補零,改為對實部與虛部分別補零。修補後的模型在 PyTorch 中數值完全相同(差異為 0.0)。
- `fix_scatternd.py` / `fix_scatternd2.py` 改寫匯出的圖:4,096 個常數 `ScatterND` 索引張量從 `int32` 轉為 `int64`,並為圖內計算出的那一個索引插入一個 `Cast`(17,730 個節點,195 MB)。修改後 ONNX Runtime 可以載入模型。

修復後的完整模型可以載入並執行,但檔案很大,而且在單一合成測試片段上的輸出低於品質標準(與 PyTorch 比較的 SNR:鼓 39.2 dB、貝斯 62.7 dB、其他 38.6 dB、人聲 16.5 dB;標準為 50 dB 以上)。開發期間用整首歌比較的結果是 57.3 / 71.7 / 47.5 / 50.2 dB。因此最後沒有採用。

### 最終採用的拆分設計

`spike2_split_middle.py` 只匯出實數的核心(編碼器、跨域 transformer、解碼器,以及反正規化)。所有涉及複數的運算都留在 ONNX 之外:

```
Swift (Accelerate / vDSP)                        ONNX Runtime                      Swift
混音 --STFT--> z --實部視圖--> 頻譜 --正規化--> [ middle.onnx ] --> spec, wave
                                                                         spec --複數視圖--> 遮罩 --iSTFT--> + 時域分支 --> 4 軌
```

- STFT/iSTFT 在 Swift 中以 Accelerate 重新實作(`Spectrogram.swift`):`nfft = 4096`、`hop = 1024`、週期性 Hann 窗、正交縮放、置中的反射補零、去掉最高頻率格並在每側裁切 2 個 frame,與 Demucs 的 `_spec` / `_ispec` 完全一致。
- ONNX 模型的輸入為 `x`(頻譜,`[1, 4, 2048, T]`)、`xt`(波形,`[1, 2, 343980]`)和正規化統計量,輸出為 `spec` 和 `wave`。
- `Separator.swift` 負責整首歌的正規化,把歌曲切成 7.8 秒片段(重疊 25%,使用三角形權重),再將結果疊加。App 使用 `shifts = 0`(不做隨機位移平均)。
- App 使用 ONNX Runtime 的預設選項建立 session,也就是在 CPU 上執行。沒有啟用 Core ML 執行提供者。

### 驗證(在作者的 Mac 上量測)

| 檢查項目 | 腳本 | 結果 |
| --- | --- | --- |
| 拆分後的模型與完整 PyTorch 模型相同(匯出 ONNX 之前) | `spike2_split_middle.py` | 最大絕對差異 0.0 |
| ONNX 核心與 PyTorch 核心比較,單一 7.8 秒片段 | `spike2_split_middle.py` | SNR 81.8 dB(`spec`)、84.0 dB(`wave`);標準為 50 dB |
| Swift STFT/iSTFT 與 PyTorch 比較 | 開發期間的檢查(未包含在 repo 中) | 正向 132 dB、反向 137 dB;標準為 100 dB |
| 模型大小 | | 圖 2.3 MB,加上約 168 MB 的外部權重(`.onnx.data`);修復後的完整模型為 195 MB |
| 速度,單一 7.8 秒片段 | | ONNX Runtime 1.5 秒,PyTorch 1.6 秒 |
| 速度,275 秒的歌,完整 Swift 流程(CPU) | `StemsCLI` | 約 76 秒。作為參考,開發期間的比較中,PyTorch 在 CPU 上為 75 秒,ONNX Runtime 在 CPU 上為 76 秒;先前的 Python 伺服器在 Apple GPU(MPS)上處理同一首歌為 29 秒,但設定不同,數字不能直接比較。 |

以上都是單機單次的量測結果,不是正式的效能測試。原生 App 目前用速度換取不需要 Python(使用 CPU 而非 GPU);啟用 Core ML 或 Metal 執行提供者是未來可能的改進,尚未測試。

## Repo 結構

| 路徑 | 說明 |
| --- | --- |
| `app/` | Swift 套件:`StemsCore`(分離、STFT、節拍分析、播放器)、`StemsApp`(SwiftUI App)、`StemsCLI`、`StemsDebug` |
| `spike2_split_middle.py` | 把 HTDemucs 的神經網路核心匯出為 ONNX;這就是 App 實際使用的模型 |
| `requirements.txt` | 匯出腳本所需的 Python 套件 |
| `spike1_export_compare.py`、`spike1_diag.py`、`fix_scatternd.py`、`fix_scatternd2.py` | 早期嘗試整體匯出模型的實驗(保留作為紀錄,見上文) |
| `Assets/` | App 圖示、Logo、字型 |
| `package.sh` | 建置並打包 `.app` / `.dmg` |
| `THIRD_PARTY_NOTICES.md` | 本專案所依賴的軟體與模型的授權 |

## 未來工作

- **硬體加速。** 目前 App 透過 ONNX Runtime 在 CPU 上執行模型。Swift 套件已經提供 Core ML 執行提供者(`appendCoreMLExecutionProviderWithOptionsV2`),第一步可以改成可選功能(運算單元設為 `CPUAndGPU`、`CPUAndNeuralEngine` 或 `All`),並與 CPU 路徑比較。需要確認的項目包括:GPU / Neural Engine 的 FP16 精度是否仍達到上述 50 dB 的標準、Core ML 實際接受的圖比例、168 MB 權重的首次載入編譯時間。另一個較大的方案是用 `coremltools` 直接轉換模型核心。
- 在背景程序或較小的區塊中執行分離,降低處理長歌時的記憶體用量。
- 經過公證的簽章發佈版本(目前的 `package.sh` 只做臨時簽章)。

## 授權

StemsCraft 本身的原始碼以 [MIT 授權](LICENSE)釋出,版權所有 (c) 2026 北極熊喝水。

第三方授權的完整內容與其要求的聲明,請見 [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)。

## 第三方軟體、模型與素材

StemsCraft 建立在以下的成果之上。它們的版權與授權仍歸原作者所有,**不會**因為 StemsCraft 採用 MIT 授權而改變。

| 元件 | 用途 | 版權 | 授權 |
| --- | --- | --- | --- |
| [Demucs / HTDemucs](https://github.com/facebookresearch/demucs)(程式碼與預訓練的 `htdemucs` 權重) | 音源分離。`spike2_split_middle.py` 產生的 ONNX 模型,以及 Swift 的 STFT/遮罩流程(`Spectrogram.swift`、`Separator.swift`),都是從這個模型和程式碼衍生的。 | Copyright (c) Meta Platforms, Inc. and affiliates | MIT |
| [ONNX Runtime](https://github.com/microsoft/onnxruntime),透過 [onnxruntime-swift-package-manager](https://github.com/microsoft/onnxruntime-swift-package-manager) | 在裝置上執行模型,已連結進 App。 | Copyright (c) Microsoft Corporation | MIT |
| [Barlow](https://github.com/jpt/barlow) 與 Barlow Condensed 字型(`Assets/Fonts`) | 介面字型。授權內容見 `Assets/Fonts/OFL.txt`。 | Copyright 2017 The Barlow Project Authors | SIL Open Font License 1.1 |
| [PyTorch](https://github.com/pytorch/pytorch)、[ONNX](https://github.com/onnx/onnx) | 僅在建置時用於匯出模型,不隨 repo 發佈。 | 各自的作者 | BSD 類 / Apache-2.0 |
| Apple 系統框架(SwiftUI、AVFoundation、Accelerate) | 音訊解碼、播放、數位訊號處理、介面。由 macOS / Xcode 提供,不隨 repo 發佈。 | Apple Inc. | Apple SDK 授權 |

`requirements.txt` 中的其他 Python 套件(numpy、onnx、onnxscript、onnxruntime)只用於匯出模型,不隨 StemsCraft 發佈,各自有其授權。

如果你使用或引用這個模型,請也引用原始論文:

> Simon Rouard, Francisco Massa, Alexandre Défossez. *Hybrid Transformers for Music Source Separation.* arXiv:2211.08553 (2022).

## 免責聲明

請只處理你有權使用的音訊。本 repo 不包含任何受版權保護的音樂,作者對於 App 的使用方式不負任何責任。
