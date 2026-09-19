# SpectArk

[English](README.md) · **한국어**

[![Release](https://img.shields.io/github/v/release/kennss/SpectArk?color=2b9348)](https://github.com/kennss/SpectArk/releases/latest)
[![Downloads](https://img.shields.io/github/downloads/kennss/SpectArk/total?color=2b9348)](https://github.com/kennss/SpectArk/releases)
[![License: MIT](https://img.shields.io/github/license/kennss/SpectArk)](LICENSE)
![Platform](https://img.shields.io/badge/platform-macOS%2014%2B%20·%20Universal-111)

![SpectArk](docs/hero.png)

정말 소중한 폴더만 골라서, 바뀌는 즉시 버전별로 백업하는 macOS 네이티브 앱이에요
(Calida Lab / Specta 제품군).

## 다운로드

**[⬇ 최신 DMG 받기](https://github.com/kennss/SpectArk/releases/latest)** — 열어서
**SpectArk**를 응용 프로그램 폴더로 끌어다 놓으면 돼요. Developer ID로 서명하고 Apple
공증을 받았어요. Apple Silicon과 Intel을 모두 지원하는 유니버설 앱이고, macOS 14 이상에서
돌아가요. 설치한 뒤에는 앱이 스스로 업데이트해요(**Check for Updates…**).

릴리즈 노트와 이전 버전은 [Releases 페이지](https://github.com/kennss/SpectArk/releases)에
있어요.

## 왜 SpectArk인가요?

Time Machine처럼 시점별로 되돌릴 수 있는 방식은 정말 좋아해요. 그런데 개발자로서 쓰기엔
맞지 않는 부분이 있었어요.

- **시스템 전체 백업은 필요 없어요.** Time Machine은 OS와 앱, 라이브러리까지 복사해요.
  맥이 망가지면 그런 건 다시 설치하면 그만이에요. 다시 설치할 수 없는 건 따로 있어요.
  지금 작업 중인 소스 코드와 프로젝트요.
- **예약 백업에는 늘 빈틈이 있어요.** 간격이 길면 최신 코드를 잃을 수 있고, 짧아도
  머피의 법칙이 찾아오는 순간 마지막 몇 분은 날아가요. Git도 커밋한 것만 지켜주지,
  커밋과 커밋 *사이*의 작업은 지켜주지 못해요.
- **그래서 코드가 바뀌는 대로 따라가는 백업이 필요했어요.** 작업 중인 폴더를 지정하면
  모든 변경이 몇 초 안에 백업되고, 되돌아갈 복원 지점이 최대 15분마다 남아요. 예약도
  빈틈도 없어요. 이 앱이 존재하는 이유가 바로 이 실시간 동작이에요.
- **드라이브 하나를 통째로 내주고 싶지도 않았어요.** 백업 전용 디스크를 따로 두는 건
  낭비처럼 느껴졌어요. 백업을 어디에 둘지 직접 고르고, 어떤 폴더든 원하는 목적지와
  자유롭게 짝지을 수 있어야 했어요.
- **백업이 유출 경로가 되면 안 돼요.** 백업 드라이브나 NAS는 잃어버리거나 도난당할 수
  있고, 평문 백업은 그 안의 파일을 전부 넘겨주는 셈이에요. 그래서 어떤 백업이든
  종단 간 암호화를 켤 수 있어요. 비밀번호로만 열리고, 비상용으로 한 번만 보여주는 복구
  키가 있어요. 암호화는 선택이고 기본은 꺼져 있어요. 필요 없을 땐 백업이 Finder에서
  바로 열리는 평범한 파일로 남아요.

그렇게 나온 게 SpectArk예요. 실시간으로, 폴더 단위로, 버전별로 백업하고 원하면
암호화까지 해요. 정말 중요한 파일을 지키고, 어디에 둘지는 내가 정해요.

## 기능

- **끊김 없는 보호와 Time Machine 방식의 복원 지점**: 모든 변경이 몇 초 안에 백업되고,
  복원 지점은 최대 15분마다 남아요. 최근 24시간은 전부, 한 달까지는 하루에 하나, 그
  이후로는 한 주에 하나씩 보관해요. 바뀐 파일만 복사하고, 어느 폴더가 바뀌었는지는 macOS
  파일 시스템 저널에서 알아내요. SpectArk가 꺼져 있던 동안의 변경까지요.
- **백업마다 실시간 또는 예약** — 폴더를 실시간으로 지켜보거나, 정해진 간격으로 돌려요.
- **여러 원본 폴더**, 각각 원하는 목적지와 짝지을 수 있어요.
- **로컬 디스크나 NAS**를 목적지로 쓸 수 있어요. NAS 백업은 공유 폴더 안의 디스크
  이미지에 들어가고, 타임라인과 복원을 앱에서 그대로 쓸 수 있어요. 목적지는 macOS가
  어디에 마운트하든 알아서 찾아가요.
- **백업 디스크의 여유 공간을 지켜요**: 모든 백업 디스크의 5%(또는 직접 정한 만큼)를
  비워 두고, 모자라면 그 디스크의 모든 백업을 통틀어 가장 오래된 복원 지점부터 지워요.
- **선택적 암호화**: 내용 기반 청킹과 중복 제거, AES-256-GCM, argon2id로 만든 키, 한
  번만 보여주는 복구 키. 기본은 꺼져 있어요(백업이 평문 그대로 탐색 가능).
- **다시 만들 수 있는 파일은 건너뛰어요**(의존성 폴더, 빌드 결과물, 캐시). 그 폴더를
  만든 도구를 확실히 알아볼 때만 건너뛰어요.
- **대시보드 창 + 메뉴 막대 드롭다운**(실시간 전송 속도, 여유 공간, 마지막 백업). 로그인
  시 조용히 열려요.
- 샌드박스 없는 Developer ID 배포, macOS 14 이상.

## 시작하기

1. **+** 버튼으로 **백업을 추가해요.** 지킬 폴더와 목적지를 고르면 돼요. 목적지는 어느
   디스크의 폴더든, Finder에 마운트한 NAS 공유 폴더든 괜찮아요. **Realtime**(파일이
   바뀔 때마다 백업)이나 **Scheduled**(정해진 간격마다)를 고르고, 원하면 암호화를 켜요.
   비밀번호를 정하고, 한 번만 보여주는 복구 키를 꼭 저장해 두세요.
2. **권한을 물어보면 허용해요.** SpectArk가 데스크탑, 도큐멘트, 다운로드 폴더를 처음 읽을 때
   macOS가 물어봐요. 그 밖의 보호된 위치(다른 사용자의 폴더, 사진 보관함 등)를 백업하려면
   **시스템 설정 ▸ 개인정보 보호 및 보안 ▸ 전체 디스크 접근 권한**에서 SpectArk를 켠 뒤,
   SpectArk를 종료했다가 다시 열어요.
3. **로그인 시 열기**를 켜요(**Settings ▸ General**, 또는 실시간 백업 화면의 안내에서).
   실시간 백업은 SpectArk가 열려 있을 때만 동작해요. 로그인할 때는 창도 Dock 아이콘도 없이
   메뉴 막대에서 조용히 시작해요.
4. **기록을 얼마나 남길지** 각 백업의 **⋯ ▸ Settings**에서 정해요. Automatic(Time Machine
   방식), 최신 N개만, N일 치만, 전부 보관 중에서 고를 수 있어요. 최대 크기와, 백업 디스크에
   비워 둘 여유 공간(0 = 자동, 디스크의 5%)도 정할 수 있어요.

## 복원하기

- **⋯ ▸ Restore…**(또는 백업을 우클릭): 복원 지점을 고르고, 되돌릴 파일과 폴더를 체크한
  다음, 원래 위치나 다른 폴더로 복원해요. 같은 이름의 파일이 이미 있을 때 어떻게 할지도
  고를 수 있어요. 암호화된 백업은 복원 지점 하나를 통째로, 원하는 폴더에 복원해요.
- **최신 백업 상태는 평범한 폴더예요.** 로컬 디스크에 있는 백업이라면, 목적지 카드를
  클릭하면 Finder에서 열려서 파일을 바로 꺼내 쓸 수 있어요.

## 빌드

Xcode 프로젝트는 [XcodeGen](https://github.com/yonaskolb/XcodeGen)으로 만들어요.

```sh
brew install xcodegen      # 한 번만
xcodegen generate          # SpectaBackup.xcodeproj 생성
open SpectaBackup.xcodeproj
```

명령줄에서 바로 빌드할 수도 있어요.

```sh
xcodegen generate
xcodebuild -project SpectaBackup.xcodeproj -scheme SpectaBackup -configuration Release build
```

`SpectaBackup.xcodeproj`는 생성되는 파일이라 git에서 제외되고, `project.yml`이 기준이에요.
프로젝트와 스킴은 예전 이름 `SpectaBackup`(번들 ID `ai.calidalab.spectabackup`)을 그대로
써요. 이름을 바꿔도 기존 백업, 키체인 항목, 전체 디스크 접근 권한이 그대로 이어지게 하려고요.
빌드된 앱 이름은 `SpectArk.app`이에요. 릴리즈(서명, 공증, DMG, Sparkle appcast)는
`scripts/release.sh`로 만들어요.

## 데이터 무결성

백업 엔진은 정확성을 기준으로 고른 macOS 기본 기능 위에 만들었어요.
- 모든 변경은 디스크를 건드리기 전에 SQLite 카탈로그에 먼저 기록돼요. 그래서 중간에 끊긴
  패스는 다음 패스에서 복구돼요.
- 복사본은 `fsync`한 뒤 원자적 `rename`으로 제자리에 놓고, 카탈로그는 `F_FULLFSYNC`로
  커밋해요.
- 복사한 파일은 모두 원본과 대조하고, 읽는 동안 원본이 바뀌었으면 그 복사본은 버려요.
  그래서 반쯤 쓰인 파일이 기록되는 일은 없어요.

다만 서로 맞아야 하는 파일들(데이터베이스와 그 `-wal` 파일 같은)은 한 순간에 함께가
아니라 하나씩 차례로 복사돼요. 소스 스냅샷을 쓰려면 root 권한과 Apple이 따로 내주는
entitlement가 필요해요([TODO.md](TODO.md) 참고). 백업 엔진은
[`docs/INCREMENTAL_ENGINE_DESIGN.md`](docs/INCREMENTAL_ENGINE_DESIGN.md), 암호화 저장소는
[`docs/ENCRYPTION_DESIGN.md`](docs/ENCRYPTION_DESIGN.md)에 설계가 정리돼 있어요.

## 로드맵

앞으로 할 일은 우선순위 순으로 [TODO.md](TODO.md)에, 지난 릴리즈는
[CHANGELOG.md](CHANGELOG.md)에 있어요. 기여는 언제든 환영해요.

## 라이선스

MIT © 2026 Kennt Kim (Calida Lab) — [LICENSE](LICENSE) 참고.
