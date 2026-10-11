# 音乐播放器（Music Player）

简洁美观的联网音乐播放器，Flutter 编写，可一键构建 Android APK。

## 功能

- 歌曲搜索（yinyueku 音乐接口）
- 热门推荐（网易云官方飙升榜）
- 歌曲收藏（爱心按钮，本地持久化）
- 自制歌单：新建歌单、添加/移出歌曲、播放全部
- 播放页：播放/暂停、上一首/下一首、进度拖动、加入歌单
- 迷你播放器：底部常驻，点击进入播放页

## 运行 / 构建

### 方式一：GitHub Actions 自动构建 APK（推荐）

1. 把本目录推送到 GitHub 仓库（`main` 或 `master` 分支）。
2. Actions 里的 `Build Android APK` 工作流会自动运行，完成后产出 APK。
3. 在仓库 **Actions → 该次运行 → Artifacts** 下载 `music-player-apk`，里面是
   `arm64-v8a / armeabi-v7a / x86_64` 三个分 ABI 的 release APK。

> `android/` 目录没有提交到仓库，由 CI 里的 `flutter create . --platforms android`
> 按当前 Flutter 版本自动生成（含 Gradle wrapper），并自动补上 release 包所需的
> `INTERNET` 联网权限。

### 方式二：本地构建

本机需安装 Flutter SDK，然后：

```bash
flutter create . --platforms android   # 首次生成 android/ 工程
flutter pub get
flutter build apk --release
```

## 为什么需要 Gradle？

Android 工程（无论 Flutter 还是原生）都是用 **Gradle** 作为构建系统来打 APK。
Gradle 的 **wrapper**（`gradle-wrapper.jar` + `gradle-wrapper.properties`）是一个
“版本封装器”：只要本机有 Java，运行 `./gradlew` 就会按 `properties` 里写死的版本
自动下载对应的 Gradle，无需手动安装。

本项目的 `android/`（含 Gradle wrapper）由 `flutter create .` 在 CI/本机自动生成，
所以**仓库里不需要手动放 gradle-wrapper.jar**。之前需要单独下载它，是因为打算在本机
手搭 android/ 工程；现在改为 CI 生成，这一步省掉了。

## 音乐接口说明

基于 yinyueku 的公开接口 `https://www.yinyueku.cn/api.php`：

- 搜索：`types=search&name=关键词`
- 热门榜单：`types=playlist&id=19723756&source=netease`
- 真实播放地址：`types=url&id=..&source=..&sign=..`（必须带返回的 `sign`）

> 注意：该接口的封面/歌词能力不可用，本应用用确定性渐变封面兜底；接口为第三方
> 免费服务，可能限流或变更，若失效可替换 `lib/api.dart` 中的 `MusicApi` 实现。

## 目录结构

```
lib/
  api.dart      # 歌曲模型 + yinyueku 接口封装
  main.dart     # 全局状态(收藏/歌单/播放) + 全部界面
test/           # 冒烟测试
.github/workflows/build_apk.yml   # GitHub Actions：自动打 APK
```
