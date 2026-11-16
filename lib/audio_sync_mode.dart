enum AudioSyncMode {
  off('不同步'),
  on('同步'),
  headphones('耳机插入时自动同步');

  const AudioSyncMode(this.label);
  final String label;
  static AudioSyncMode parse(dynamic value) => AudioSyncMode.values.firstWhere(
    (mode) => mode.name == value,
    orElse: () => AudioSyncMode.off,
  );
}
