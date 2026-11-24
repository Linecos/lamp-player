import 'package:flutter_test/flutter_test.dart';
import 'package:lamp_player/src/features/library/library_page.dart';
import 'package:lamp_player/src/rust/api/player.dart' as rust;

void main() {
  const rust.PlayerDevice speaker = rust.PlayerDevice(
    index: 1,
    name: '扬声器',
    isDefault: true,
  );
  const rust.PlayerDevice buds = rust.PlayerDevice(
    index: 2,
    name: 'XX 的 Buds',
    isDefault: false,
  );

  test('列表完全一致才判「没变化」', () {
    expect(
      samePlayerDevices(
        const <rust.PlayerDevice>[speaker, buds],
        const <rust.PlayerDevice>[speaker, buds],
      ),
      isTrue,
    );
    expect(
      samePlayerDevices(
        const <rust.PlayerDevice>[],
        const <rust.PlayerDevice>[],
      ),
      isTrue,
    );
  });

  test('索引不变、名字变了要判变化', () {
    // 蓝牙耳机醒来改名：BASS 索引还是 2，但界面该刷新
    expect(
      samePlayerDevices(
        const <rust.PlayerDevice>[
          speaker,
          rust.PlayerDevice(index: 2, name: 'XX 的 Buds Pro', isDefault: false),
        ],
        const <rust.PlayerDevice>[speaker, buds],
      ),
      isFalse,
    );
  });

  test('索引与名字不变、默认标记挪了要判变化', () {
    expect(
      samePlayerDevices(
        const <rust.PlayerDevice>[
          rust.PlayerDevice(index: 1, name: '扬声器', isDefault: false),
          rust.PlayerDevice(index: 2, name: 'XX 的 Buds', isDefault: true),
        ],
        const <rust.PlayerDevice>[speaker, buds],
      ),
      isFalse,
    );
  });

  test('条数变了要判变化', () {
    expect(
      samePlayerDevices(
        const <rust.PlayerDevice>[speaker],
        const <rust.PlayerDevice>[speaker, buds],
      ),
      isFalse,
    );
  });
}
