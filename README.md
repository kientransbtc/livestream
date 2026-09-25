# Hisale Coaching Hub — demo LiveKit

Demo Flutter trong project `hi_zoom`.

## Chạy thử

1. Chạy app trên hai thiết bị có Internet.
2. Nhập cùng **Tên phòng** trên hai máy và nhập **Tên của bạn**.
3. Máy đầu chọn **Chủ phòng**, bấm **Vào phòng**.
4. Máy sau chọn **Thành viên**. Nếu vẫn chọn Chủ phòng mà phòng đã có host,
   app thông báo và chuyển người này thành thành viên.

Mỗi lần bấm Vào phòng, app tự ký JWT mới ở bên trong, không hiển thị ô token.
Token có hạn 1 giờ, giới hạn vào tên phòng vừa nhập và có identity riêng.
Thông tin project demo và hàm ký token nằm ở `lib/demo_livekit_token.dart`.
Luồng demo này không cần chạy token server ở cổng 8787.

## Trong phòng

- Nút **Chia sẻ** nằm ngay trên thanh điều khiển chính; sau khi host cấp quyền,
  bấm nút này để bắt đầu hoặc dừng chia sẻ. Chat cũng luôn nằm trên thanh chính.
  Nút **Thành viên** và các mục phụ nằm trong menu **Thêm**, cùng với lựa chọn
  màn hình của người đang chia sẻ. **Thoát app** luôn nằm riêng trên thanh chính.
  Hướng dẫn cấu hình iPhone thật và kiểm thử Android: [SCREEN_SHARING.md](docs/SCREEN_SHARING.md).

- Host mặc định ở khung lớn giữa màn hình; các thành viên khác ở hàng bên dưới.
- Xoay thiết bị sang ngang để dùng bố cục video lớn bên trái và danh sách thành
  viên bên phải; camera giữ nguyên tỉ lệ, phần trống hai bên dùng nền đen như
  Zoom và mirror phù hợp với hướng mới.
- Chạm khung của một người hoặc chọn trong danh sách Thành viên để xem riêng
  người đó. Chạm lại khung hoặc bấm **Trở về chủ phòng** để hiện cả phòng.
- Icon mic/camera đọc trạng thái track từ LiveKit. Khi camera tắt, khung hiện avatar.
- Khi camera đang bật, nút **Cam sau/Cam trước** xuất hiện để đổi camera. Camera
  mới bật mặc định là camera trước; khi camera tắt, nút đổi camera được ẩn.
- Học viên giơ tay; host có thể cấp riêng quyền **mic** hoặc **chia sẻ màn hình**
  cho từng người. Nút **Duyệt tất cả** cấp cả hai quyền cho toàn bộ người đang
  chờ. Hộp thoại duyệt mặc định chọn cả hai quyền; host có thể bỏ chọn trước
  khi bấm **Đồng ý**.
- Khi vào phòng, mic/camera đều tắt. Khi bấm bật, app xin quyền thiết bị trước
  khi gọi LiveKit. Host duyệt phát biểu không thay thế quyền micro của điện thoại.
- Chia sẻ màn hình chỉ gửi video; âm thanh cuộc gọi dùng track microphone LiveKit
  riêng. Duyệt mic trên UI demo không thay đổi quyền trong JWT/server.
- Nếu đã từ chối quyền, dùng **Mở Cài đặt**, cấp quyền rồi quay lại bấm bật.
- Camera không khả dụng trên iOS Simulator được báo riêng, không báo nhầm thành
  thiếu quyền. Thiếu quyền camera không chặn micro và ngược lại.
- Thanh điều khiển chính dùng các nút nhỏ để giữ mic, cam, chat, chia sẻ và giơ
  tay trên cùng một hàng; các chức năng phụ mở từ **Thêm**.
- **Chat** bật/tắt khung chat bán trong suốt trên video. Nhập tin rồi bấm mũi tên
  xanh để gửi cho cả phòng; mỗi tin có tên người gửi và giờ gửi.
- Khi ẩn chat, app vẫn nhận tin và hiện số tin chưa đọc trên nút Chat. Bấm lại
  để xem; nội dung đang soạn vẫn được giữ khi đóng/mở khung chat.
- iOS Simulator có thể không phát được camera; dùng iPhone thật để thử hình ảnh.

## Chat demo

Chat dùng LiveKit text streams, topic `hisale.chat`, không cần backend và không
phụ thuộc quyền bật mic/camera. Mỗi tin tối đa 1.000 ký tự. App giữ tối đa 200 tin
trong bộ nhớ của lần tham gia hiện tại; rời phòng sẽ xóa lịch sử trên thiết bị.
Người vào sau hoặc mất kết nối không được tải lại tin đã bỏ lỡ. Đây là chat chung
trong phòng, chưa có nhắn riêng hoặc trạng thái xác nhận người khác đã đọc.

Thử trên hai thiết bị cùng tên phòng: gửi từ host sang thành viên và ngược lại;
ẩn chat ở một máy, gửi thêm tin từ máy kia rồi bấm Chat để xem số tin mới và lịch sử.

## Khi chuyển vào HiSale thật

API secret và phần ký JWT phải chuyển về backend. Backend xác thực người dùng,
chốt host duy nhất trong một transaction trước khi cấp token và quản lý quyền
publish qua LiveKit. Demo hiện chọn host bằng metadata và thứ tự tham gia;
việc giơ tay/duyệt mic chỉ mô phỏng ở client. Đây chưa phải cơ chế phân quyền
cho production.

## Dùng như module trong app HiSale

Package này chỉ cung cấp UI/kết nối meeting. Màn list room, detail room,
repository và Riverpod controller nằm ở app chính trong
`lib/features/meeting`. App chính dùng `lib/livekit_lib.dart`, không gọi
`main.dart` trực tiếp, và chỉ khởi tạo meeting sau khi backend trả credentials:

```dart
LiveKitMeetingPage(
  room: room,
  credentials: credentials,
  participantName: currentUser.name,
)
```

Backend cần cung cấp:

- `GET /hisale-live-api/api/livekit/rooms`: trả object có `rooms`; mỗi room dùng `room_id`,
  `room_name`, `metadata.description`, `num_participants`,
  `max_participants` và `active_recording`.
- `POST /hisale-live-api/api/livekit/create-room`: nhận `room_name`,
  `user_id` dạng string, `ttl` tính bằng giây và tùy chọn `description`; app
  nhận số phút ở form rồi đổi sang giây trước khi gửi. User được gửi thêm qua
  header `X-User-Id`, `X-User-Name`.
- `POST /hisale-live-api/api/livekit/token` với body `room_id`, `user_id` dạng string
  và `participant_name`: trả `server_url`, `participant_token` và tùy chọn `role`.
  Token cho host/người được phép phát biểu phải có `canSubscribe: true`; người nói
  cần `canPublish: true` (và `canPublishSources` phải cho phép `MICROPHONE`, nếu
  backend giới hạn nguồn). Gói quyền host/member cần thống nhất để host nhận được
  track mic của member. UI host duyệt mic hiện chỉ là demo client-side, backend
  production phải tự xác thực và cập nhật quyền LiveKit khi duyệt.

Sau khi tạo phòng thành công, màn hình đóng bottom sheet và gọi lại API danh sách
phòng. Chỉ khi API cấp token tham gia thành công thì màn hình meeting mới được
khởi tạo.

Mobile chỉ truyền `server_url` và `participant_token` cho LiveKit. API key/API
secret không được đưa xuống mobile. Nếu chạy demo độc lập, truyền credentials
qua `--dart-define=LIVEKIT_API_KEY=...` và `--dart-define=LIVEKIT_API_SECRET=...`;
không ghi chúng vào source code.

Để lưu chat trong HiSale thật: app gửi API chat của backend; backend xác thực,
kiểm quyền/khóa chat, lưu tin rồi phát qua LiveKit. App lấy lịch sử/tin bỏ lỡ qua
API và chống trùng theo ID. Không vừa gửi trực tiếp qua LiveKit vừa POST cùng tin
lên backend. Luồng text streams hiện tại chỉ phục vụ demo chưa có backend.
