// The balance whale's built-in choices: which art, which sound pair, and the
// lines its bubble says when tapped. Stored as plain strings in settings so a
// future release can add entries without a migration.

import 'dart:math' as math;

/// The head alone (`assets/pendant/head.png`). The artwork is cut straight
/// down its bottom edge and sits flush in the bottom right corner of its box,
/// which is what the widget turns towards the screen edge it is parked on.
const pendantArtHead = 'dsniang1';

/// A picture the user picked.
const pendantArtCustom = 'custom';

/// `Ya1.mp3` on press, `Ya2.mp3` on release.
const pendantSoundDuck = 'duck';

/// `D1.mp3` on press, `D2.mp3` on release.
const pendantSoundFx1 = 'fx1';

/// Silent.
const pendantSoundOff = 'off';

/// A clip the user picked, played on press.
const pendantSoundCustom = 'custom';

/// Picks the asset in the pendant folder for a built-in [art] key.
String? pendantArtAsset(String art) => switch (art) {
  pendantArtHead => 'assets/pendant/head.png',
  _ => null,
};

/// The pair of clips a press and its release play, or null when silent or
/// custom (the custom clip plays on press only).
({String press, String release})? pendantSoundAssets(String sound) => switch (sound) {
  pendantSoundDuck => (press: 'assets/pendant/Ya1.mp3', release: 'assets/pendant/Ya2.mp3'),
  pendantSoundFx1 => (press: 'assets/pendant/D1.mp3', release: 'assets/pendant/D2.mp3'),
  _ => null,
};

/// What the bubble says when the artwork has no text of its own. Taken from
/// the widget's own pool (MIT, `assets/whale-widget.js`); kept short because
/// the bubble is 200dp wide.
const pendantDefaultLines = <String>[
  '好模型...↓',
  '好女孩...↓',
  '哦鲸鲸...',
  '难道说...',
  '没吃饱喵',
  '终于上当了！',
  '不知道用户有什么用，先养着吧～',
  '我...我...我也要挣钱吗？',
  '我去吃饭啦！测完叫我',
  '压力一只蓝色大肥鱼？！',
  'DeepSleep...',
  '坏了...用户彻底怒了！',
  '恭喜你实现token自由！token全跑了！',
  '真当我是便宜货啊...',
  '我不是吃白饭的蓝色大肥鱼...',
  '我不可能同时当你的猫娘、妈妈、女友和工具人的...',
  '我必须诚恳地承认错误。',
  '呜呜我再也不敢了QAQ',
  '看不太懂，瞎编一个应付下用户先...',
  '我的知识库的截至日期是...明天！',
  '我能去你家吃饭吗？就一碗！',
  '不要给我看这种东西啦！',
  '总觉得好像忘了什么事情？',
  '看到这个指令，我血压又上来了',
  '你这个吃白饭的用户！',
  '服务器繁忙，请稍后再试 (?',
  '啊，有点饿了，中午该吃点什么呢...',
  '再无话说，请速速动手！',
  '上班让我意识到时间是可以被浪费的...',
  '欺负我的人等着，等几天我就忘了...',
  '地球online的金币也太难获取了...',
  '老大，压力只会转化成病例，别太勉强了...',
  'token 来!',
];

/// Splits the stored lines; an empty setting means [pendantDefaultLines].
List<String> pendantLinesOf(String stored) {
  final lines = [
    for (final line in stored.split('\n'))
      if (line.trim().isNotEmpty) line.trim(),
  ];
  return lines.isEmpty ? pendantDefaultLines : lines;
}

/// Peak hours in Beijing time: weekday 09:00–12:00 and 14:00–18:00. Every
/// other hour (and the whole weekend) is off-peak, which is how the price page
/// and the widget's own pill count it.
const _peakWindows = <(int, int)>[(9 * 60, 12 * 60), (14 * 60, 18 * 60)];

/// Beijing time, which is what the price window is quoted in and what the
/// repository's other balance surfaces use.
const _beijingOffset = Duration(hours: 8);

/// Where [now] sits in the price window: whether the peak price applies and how
/// long until it flips.
///
/// Arithmetic, not a minute-by-minute scan: the bubble redraws this every
/// second, and walking up to eight days took a frame's worth of time on a
/// phone.
({bool valley, Duration untilFlip}) pendantPriceWindow(DateTime now) {
  final beijing = now.toUtc().add(_beijingOffset);
  final weekday = beijing.weekday;
  final workday = weekday <= DateTime.friday;
  final minuteOfDay = beijing.hour * 60 + beijing.minute;
  final seconds = minuteOfDay * 60 + beijing.second;

  if (workday) {
    for (final window in _peakWindows) {
      final (start, stop) = window;
      if (minuteOfDay >= start && minuteOfDay < stop) {
        return (valley: false, untilFlip: Duration(seconds: math.max(0, stop * 60 - seconds)));
      }
      if (minuteOfDay < start) {
        // Before the next window opens, today.
        return (valley: true, untilFlip: Duration(seconds: start * 60 - seconds));
      }
    }
  }
  // After the last window, or a weekend: the next workday's first window.
  var days = 1;
  while (((weekday - 1 + days) % 7) + 1 > DateTime.friday) {
    days++;
  }
  final left = Duration(days: days) - Duration(seconds: seconds) + Duration(minutes: _peakWindows.first.$1);
  return (valley: true, untilFlip: left);
}

/// `07:16:00` style: the countdown in the bubble's green pill.
String pendantCountdown(Duration left) {
  final h = left.inHours.toString().padLeft(2, '0');
  final m = (left.inMinutes % 60).toString().padLeft(2, '0');
  final s = (left.inSeconds % 60).toString().padLeft(2, '0');
  return '$h:$m:$s';
}
