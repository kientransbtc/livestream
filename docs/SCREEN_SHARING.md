# Chia sẻ màn hình — hisale live

## Sử dụng

Vào phòng → **Chia sẻ** trên thanh điều khiển → xác nhận hộp thoại hệ điều hành.
Mở tài liệu hoặc ứng dụng muốn trình bày. Người còn lại trong phòng sẽ nhận
luồng màn hình riêng với camera. Bấm lại **Dừng share** để kết thúc.
Tất cả người có quyền publish screen_share đều được chia sẻ trong demo;
việc host duyệt mic không cấp hoặc thu hồi quyền chia sẻ màn hình.

Khung màn hình dùng contain, không cắt tài liệu. Camera vẫn hiện ở dải thành viên.
Máy gửi hiển thị thông báo thay cho preview để tránh màn hình lặp vô hạn.
Khi có nhiều người chia sẻ, chọn **Thêm → Xem màn hình: tên** để đổi người xem.
Chat vẫn bật/tắt bằng nút Chat. Chia sẻ màn hình hiện chỉ truyền video; âm thanh
hội thoại host/thành viên tiếp tục chạy riêng trên track microphone LiveKit.

## iOS: phần đã cấu hình và bước trên tài khoản Apple

Đã thêm target ScreenShareExtension, nhúng extension trong Runner, cấu hình
App Group cho cả hai và bật chế độ Broadcast Extension trong RoomOptions.
Giữ mức iOS 15 của project, đáp ứng yêu cầu iOS 14+ của extension mẫu.

Các giá trị đang dùng:

| Thành phần | Identifier |
| --- | --- |
| Runner | com.example.hiZoom |
| ScreenShareExtension | com.example.hiZoom.ScreenShareExtension |
| App Group chung | group.com.example.hiZoom |

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
7. Mở Safari hoặc trình xem PDF để xác nhận người còn lại nhận được video màn
   hình. Âm thanh từ ứng dụng đang share hiện không được thu/phát.

Simulator chỉ dùng kiểm tra build/giao diện; app sẽ hướng dẫn dùng iPhone thật
khi bấm chia sẻ. Cấu hình trong project không đồng nghĩa App Group đã được cấp
trên Apple Developer Portal. Không tự động thay đổi tài khoản hay provisioning
trên portal trong lần triển khai này.

Mã extension dựa trên mẫu LiveKit Flutter, giữ thông tin tác giả và LICENSE.livekit:
https://github.com/livekit/client-sdk-flutter/tree/main/example/ios/LiveKit%20Broadcast%20Extension
Đã bổ sung nhận `iOS_BroadcastRequestStop` và timeout kết nối. Extension chỉ
xử lý frame video; callback âm thanh ReplayKit không được ghi hay gửi.

## Android

Đã khai báo foreground service loại mediaProjection và hai quyền FOREGROUND_SERVICE,
FOREGROUND_SERVICE_MEDIA_PROJECTION; icon thông báo riêng. SDK xin quyền capture mới
trước mỗi lần chia sẻ, sau đó khởi động service rồi mới publish. Nếu người dùng
hủy, không publish. Không yêu cầu tắt tối ưu pin. Rời phòng/dừng capture sẽ giải
phóng service do phiên chia sẻ này khởi động.

Build lại app với `flutter pub get` và `flutter run`. Kiểm thử trên thiết bị
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
