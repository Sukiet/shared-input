class LocalKeyException {
  const LocalKeyException(this.key, this.label);
  final int key;
  final String label;
  String get code =>
      'VK 0x${key.toRadixString(16).toUpperCase().padLeft(2, '0')}';
  Map<String, dynamic> toJson() => {'key': key, 'label': label};
  static LocalKeyException? fromJson(dynamic value) {
    if (value is! Map) return null;
    final key = value['key'], label = value['label'];
    if (key is! int || key < 8 || key >= 255 || key == 0xe5 || key == 0xe7) {
      return null;
    }
    return LocalKeyException(
      key,
      label is String && label.trim().isNotEmpty && label.length <= 80
          ? label
          : '按键 $key',
    );
  }
}
