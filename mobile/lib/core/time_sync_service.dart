class TimeSyncService {
  final List<double> _offsetSamples = <double>[];
  final List<double> _rttSamples = <double>[];

  static const int _maxSamples = 15;

  void addSample({
    required int t0ClientSendMs,
    required int t1ServerRecvMs,
    required int t2ServerSendMs,
    required int t3ClientRecvMs,
  }) {
    final offset =
        ((t1ServerRecvMs - t0ClientSendMs) + (t2ServerSendMs - t3ClientRecvMs)) / 2;
    final rtt =
        (t3ClientRecvMs - t0ClientSendMs) - (t2ServerSendMs - t1ServerRecvMs);

    _push(_offsetSamples, offset);
    _push(_rttSamples, rtt.toDouble());
  }

  int get offsetMs => _median(_offsetSamples).round();
  int get rttMs => _median(_rttSamples).round();

  void _push(List<double> samples, double value) {
    samples.add(value);
    if (samples.length > _maxSamples) {
      samples.removeAt(0);
    }
  }

  double _median(List<double> values) {
    if (values.isEmpty) {
      return 0;
    }

    final sorted = List<double>.from(values)..sort();
    final middle = sorted.length ~/ 2;

    if (sorted.length.isOdd) {
      return sorted[middle];
    }

    return (sorted[middle - 1] + sorted[middle]) / 2;
  }
}
