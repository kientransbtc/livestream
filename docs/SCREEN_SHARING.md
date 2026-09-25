# Chia sẻ màn hình — Hisale Coaching Hub

## Sử dụng

Vào phòng → **Chia sẻ** trên thanh điều khiển → xác nhận hộp thoại hệ điều hành.
Mở tài liệu hoặc ứng dụng muốn trình bày. Người còn lại trong phòng sẽ nhận
luồng màn hình riêng với camera. Bấm lại **Dừng share** để kết thúc.
Tất cả người có quyền publish screen_share đều được chia sẻ trong demo;
việc host duyệt mic không cấp hoặc thu hồi quyền chia sẻ màn hình.

Khung màn hình dùng contain, không cắt tài liệu. Camera của người chia sẻ được tắt khi bắt đầu share.
Máy gửi hiển thị thông báo thay cho preview để tránh màn hình lặp vô hạn.
Khi có nhiều người chia sẻ, chọn **Thêm → Xem màn hình: tên** để đổi người xem.
Chat vẫn bật/tắt bằng nút Chat. Native bridge trong `local_packages/flutter_webrtc`
trộn tiếng ứng dụng đang trình chiếu vào **track microphone đang bật**, sau bộ
lọc thoại WebRTC. Vì vậy người trình bày có thể nói đồng thời với video.
Tiếng hệ thống chỉ đi qua **track mic**: tắt mic thì tắt cả tiếng share.
Không publish track âm thanh thứ hai (vd. `screen_share_audio`): WebRTC bản này
mute input micro chung (ADM, `setVoiceProcessingInputMuted`) khi *bất kỳ* track
âm thanh local nào bị mute, làm mất luôn giọng người trình bày.
Không tự bật mic hoặc vượt quyền host/BE. Nếu mic đang tắt, app nhắc người dùng.
PDF/tài liệu không có media đang phát thì không có âm thanh để thu.

## iOS: phần đã cấu hình và bước trên tài khoản Apple

Đã thêm target ScreenShareExtension, nhúng extension trong Runner, cấu hình
App Group cho cả hai và bật chế độ Broadcast Extension trong RoomOptions.
Giữ mức iOS 15 của project, đáp ứng yêu cầu iOS 14+ của extension mẫu.

Các giá trị trong app HiSale (project gốc; demo standalone có identifier riêng):

| Thành phần | Identifier |
| --- | --- |
| Runner | com.hisale.homex.app |
| ScreenShareExtension | com.hisale.homex.app.ScreenShareExtension |
| App Group chung | group.com.hisale.homex.app |

Để chạy trên iPhone thật:

1. Mở `ios/Runner.xcworkspace` bằng Xcode.
2. Chọn Signing & Capabilities cho **Runner** và **ScreenShareExtension**.
   Chọn cùng Apple Developer Team có quyền App Groups và bật automatic signing.
3. Trong tài khoản Apple, đăng ký/kiểm tra App Group ở trên; cấp App Group đó
   cho App ID của cả Runner và extension, cập nhật provisioning profiles.
   Nếu tài khoản không sở hữu các identifier này, thay bằng identifier của team.
4. Xác nhận cùng App Group trong hai file entitlements, `RTCAppGroupIdentifier`
   của Runner và `SampleHandler.swift`; `RTCScreenSharingExtension` phải trùng
   bundle ID của extension. Đổi tên app hiển thị không đổi bundle ID.
5. Chọn scheme **Runner** và iPhone thật, build/run lại toàn bộ app.
   Không chỉ hot reload vì có thêm native target.
6. Vào phòng rồi chọn Chia sẻ màn hình → **Start Broadcast**. Chuyển sang Safari
   hoặc trình xem PDF; dùng máy thứ hai kiểm tra hình nhận được.
7. Bật mic trong phòng, phát một video có tiếng và kiểm tra máy nhận nghe được
   cả lời nói và tiếng video. Dùng nội dung không bảo vệ bản quyền và tai nghe
   ở máy gửi để chứng minh tiếng nhận không chỉ là loa lọt vào microphone.

Simulator chỉ dùng kiểm tra build/giao diện; app sẽ hướng dẫn dùng iPhone thật
khi bấm chia sẻ. Cấu hình trong project không đồng nghĩa App Group đã được cấp
trên Apple Developer Portal. Không tự động thay đổi tài khoản hay provisioning
trên portal trong lần triển khai này.

Mã extension dựa trên mẫu LiveKit Flutter, giữ thông tin tác giả và LICENSE.livekit:
https://github.com/livekit/client-sdk-flutter/tree/main/example/ios/LiveKit%20Broadcast%20Extension
Đã bổ sung nhận `iOS_BroadcastRequestStop` và timeout kết nối. Extension gửi
video qua `rtc_SSFD`, gửi ReplayKit `.audioApp` qua `rtc_SSFA` trong App Group.
Âm thanh được chuẩn hóa mono Float32 48 kHz; phía WebRTC đổi sang FloatS16
trước khi cộng với mic, qua bộ đệm chống giật 40 ms (tối đa 200 ms). `.audioMic` không gửi lại để tránh lặp tiếng mic.
Chỉ những mẫu âm thanh ReplayKit cung cấp mới truyền được; không vượt DRM.
Khi broadcast đã chạy, app chuyển audio session sang playAndRecord +
`mixWithOthers` (trả lại chế độ tự động của LiveKit khi dừng). Nếu không, app
đang phát nhạc/video sẽ ngắt session của mình, làm dừng mic WebRTC nên không có
buffer nào để trộn tiếng ReplayKit vào.

## Android

Đã khai báo foreground service loại mediaProjection và hai quyền FOREGROUND_SERVICE,
FOREGROUND_SERVICE_MEDIA_PROJECTION; icon thông báo riêng. SDK xin quyền capture mới
trước mỗi lần chia sẻ, sau đó khởi động service rồi mới publish. Nếu người dùng
hủy, không publish. Không yêu cầu tắt tối ưu pin. Rời phòng/dừng capture sẽ giải
phóng service do phiên chia sẻ này khởi động.

Playback capture cần Android 10+, `RECORD_AUDIO`, MediaProjection được người dùng
đồng ý và foreground service phù hợp. Chỉ thu nội dung mà ứng dụng nguồn cho
phép capture, thuộc usage MEDIA/GAME/UNKNOWN; không thể ép thu app chặn capture.
Xem [Android playback capture](https://developer.android.com/media/platform/av-capture).
PCM16 được đọc trên worker riêng, buffer tối đa 100 ms, trộn vào FloatS16 ở
capture post-processing để tiếng media không đi qua bộ lọc thoại lần nữa.

Build lại app với `fvm flutter run` (dừng phiên chạy cũ trước). Không cần clean
hoặc xóa Pods chỉ vì thay native source; hot reload/hot restart không nạp lại
native plugin/extension. Root pubspec phải override flutter_webrtc tới bản local.
Kiểm thử trên thiết bị
Android, đặc biệt Android 14+ với hộp thoại chọn app/toàn màn hình. Khi hệ điều hành
dừng capture, app theo dõi track bị kết thúc để cập nhật UI và dọn service.

## Kiểm thử nghiệm thu trên thiết bị

- iPhone gửi → Android nhận; Android gửi → iPhone nhận.
- Hủy xin phép: không hiện trạng thái đang chia sẻ, không có service còn chạy.
- Mở Safari/PDF/app khác; tài liệu ngang/dọc vẫn nhìn đủ nội dung.
- Dừng bằng menu app hoặc nút hệ thống; người xem trở lại camera/host.
- Chia sẻ lần hai phải xin phép lại trên Android.
- Rời phòng khi đang xin phép; đồng ý muộn không được publish vào phòng cũ.
- Mất mạng, đóng app, rời phòng: kiểm tra chỉ báo capture/thông báo không bị kẹt.
- Mic host → thành viên và thành viên đã được duyệt → host; camera, chat vẫn
  hoạt động; kiểm tra chữ không tràn trên điện thoại nhỏ.
- Cả hai chiều iOS/Android: bật mic, phát video có tiếng bằng tai nghe, vừa nói
  vừa share; dừng/start lại 3 lần, background/foreground, sau đó xác nhận mic vẫn nghe.
- Mic tắt/chưa được duyệt: không tự mở mic, hiện nhắc khi bắt đầu share.

## Kiểm thử PCM và chẩn đoán

Từ project gốc, chạy `bash local_packages/flutter_webrtc/native_tests/run.sh`.
Test gọi mã mixer/adapter production với buffer giả lập: gắn mixer sau khi mic
chạy, gain FloatS16, giữ nguyên mic khi thiếu dữ liệu, clipping, resample,
stereo iOS và clear queue khi dừng. Không thay thế test âm thanh giữa hai máy.

Android log tag `ScreenShareAudioMixer` phải có: `Playback capture started`,
`Received non-silent playback PCM`, `Mixing playback after microphone processing`.
Nếu capture chạy nhưng PCM toàn 0, kiểm tra video có phát/volume và chính sách
ứng dụng nguồn. Có PCM nhưng không có mixing: kiểm tra mic publication còn bật.
iOS extension log: `Screen audio socket connected`, `Screen audio socket writable`,
`First screen audio bytes sent to app`, `Screen audio stats` (mỗi 5 s). App log:
`FlutterSocketAudioReader: first ... bytes`, `ScreenShareAudioMixer: received
ReplayKit PCM`, `mixing playback`, và `ScreenShareAudioMixer stats` (mỗi 5 s, có
`micPeak`: bằng 0 nghĩa là input micro đang bị mute). Có thể xem bằng
`idevicesyslog` trong `$FLUTTER_ROOT/bin/cache/artifacts/libimobiledevice`.

Kiểm thử tự động: `flutter test --no-pub`. Kiểm thử controller dùng backend giả
để xác minh thứ tự, hủy, lỗi publish, dừng từ hệ thống và rời phòng; không thay thế
kiểm thử MediaProjection/ReplayKit thật trên hai thiết bị.

## Đưa vào HiSale production

Backend quản lý quyền publish theo nguồn `screen_share`, độc lập quyền micro.
Nếu chỉ cho một người trình bày, backend phải cấp quyền nguyên tử và thu hồi
người cũ. Demo chưa áp dụng giới hạn một người chia sẻ. JWT vẫn theo cơ chế demo
hiện có; khi production chuyển API secret và ký token về backend.

SDK 2.13.0 chưa export BroadcastManager ở entrypoint chính; adapter nhập module
`src/managers/broadcast_manager.dart`. Khi nâng LiveKit cần kiểm tra lại API này.
