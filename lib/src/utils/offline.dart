part of flutter_data;

const _offlineAdapterKey = '_offline:keys';

/// Represents an offline request that is pending to be retried.
class OfflineOperation<T extends DataModel<T>> with EquatableMixin {
  final DataRequestLabel label;
  final String httpRequest;
  final Map<String, String>? headers;
  final String? body;
  late final String? key;
  final _OnSuccessGeneric<T>? onSuccess;
  final _OnErrorGeneric<T>? onError;
  final RemoteAdapter<T> adapter;

  OfflineOperation({
    required this.label,
    required this.httpRequest,
    this.headers,
    this.body,
    String? key,
    this.onSuccess,
    this.onError,
    required this.adapter,
  }) {
    this.key = key ?? label.model?._key;
  }

  /// Metadata format:
  /// _offline:findOne/users#3@d7bcc9
  static String metadataFor(DataRequestLabel label) => '_offline:$label';

  Map<String, dynamic> toJson() {
    return <String, dynamic>{
      'r': httpRequest,
      'k': key,
      'b': body,
      'h': headers,
    };
  }

  factory OfflineOperation.fromJson(
    DataRequestLabel label,
    Map<String, dynamic> json,
    RemoteAdapter<T> adapter,
  ) {
    final operation = OfflineOperation(
      label: label,
      httpRequest: json['r'] as String,
      key: json['k'] as String?,
      body: json['b'] as String?,
      headers:
          json['h'] == null ? null : Map<String, String>.from(json['h'] as Map),
      adapter: adapter,
    );

    if (operation.key != null) {
      final model = adapter.localAdapter.findOne(operation.key!);
      if (model != null) {
        operation.label.model = model;
      }
    }
    return operation;
  }

  Uri get uri {
    return httpRequest.split(' ').last.asUri;
  }

  DataRequestMethod get method {
    return DataRequestMethod.values
        .singleWhere((m) => m.toShortString() == httpRequest.split(' ').first);
  }

  /// Adds an edge from the `_offlineAdapterKey` to the `key` for save/delete
  /// and stores header/param metadata. Also stores callbacks.
  void add() {
    // DO NOT proceed if operation is in queue
    if (!adapter.offlineOperations.contains(this)) {
      final node = json.encode(toJson());
      final metadata = metadataFor(label);

      adapter.log(label, 'offline/add $metadata');
      adapter.graph._addEdge(_offlineAdapterKey, node, metadata: metadata);

      // keep callbacks in memory
      adapter.ref.read(_offlineCallbackProvider)[metadata] ??= [];
      adapter.ref
          .read(_offlineCallbackProvider)[metadata]!
          .add([onSuccess, onError]);
    } else {
      // trick
      adapter.graph
          ._notify([_offlineAdapterKey, ''], type: DataGraphEventType.addEdge);
    }
  }

  /// Removes all edges from the `_offlineAdapterKey` for
  /// current metadata, as well as callbacks from memory.
  static void remove(DataRequestLabel label, RemoteAdapter adapter) {
    final metadata = metadataFor(label);
    if (adapter.graph._hasEdge(_offlineAdapterKey, metadata: metadata)) {
      adapter.graph._removeEdges(_offlineAdapterKey, metadata: metadata);
      adapter.log(label, 'offline/remove $metadata');
      adapter.ref.read(_offlineCallbackProvider).remove(metadata);
    }
  }

  Future<void> retry() async {
    final metadata = metadataFor(label);
    // look up callbacks (or provide defaults)
    final fns = adapter.ref.read(_offlineCallbackProvider)[metadata] ??
        [
          [null, null]
        ];

    for (final pair in fns) {
      await adapter.sendRequest<T>(
        uri,
        method: method,
        headers: headers,
        label: label,
        body: body,
        onSuccess: pair.first as _OnSuccessGeneric<T>?,
        onError: pair.last as _OnErrorGeneric<T>?,
      );
    }
  }

  T? get model => label.model as T?;

  @override
  List<Object?> get props => [label, httpRequest, body, headers];

  @override
  bool get stringify => true;
}

extension OfflineOperationsX on Set<OfflineOperation<DataModel>> {
  /// Retries all offline operations for current type.
  FutureOr<void> retry() async {
    if (isNotEmpty) {
      await Future.wait(map((operation) {
        return operation.retry();
      }));
    }
  }

  /// Removes all offline operations.
  void reset() {
    if (isEmpty) {
      return;
    }
    final adapter = first.adapter;
    // removes node and severs edges
    if (adapter.graph._hasNode(_offlineAdapterKey)) {
      final node = adapter.graph._getNode(_offlineAdapterKey);
      for (final metadata in (node ?? {}).keys.toImmutableList()) {
        adapter.graph._removeEdges(_offlineAdapterKey, metadata: metadata);
      }
    }
    adapter.ref.read(_offlineCallbackProvider).clear();
  }

  /// Filter by [label] kind.
  List<OfflineOperation> only(DataRequestLabel label) {
    return where((_) => _.label.kind == label.kind).toImmutableList();
  }
}

// stores onSuccess/onError function combos
final _offlineCallbackProvider =
    StateProvider<Map<String, List<List<Function?>>>>((_) => {});

/// Every time there is an offline operation added to/
/// removed from the queue, this will notify clients
/// with all pending types (could be none) such that
/// they can implement their own retry strategy.
final offlineOperationsProvider = StateNotifierProvider<
    DelayedStateNotifier<Set<OfflineOperation>>, Set<OfflineOperation>?>((ref) {
  final graph = ref.watch(graphNotifierProvider);

  Set<OfflineOperation> _offlineOperations() {
    return internalRepositories.values
        .map((r) => r.remoteAdapter.offlineOperations)
        .expand((e) => e)
        .toSet();
  }

  final notifier = DelayedStateNotifier<Set<OfflineOperation>>();
  // emit initial value
  Timer.run(() {
    if (notifier.mounted) {
      notifier.state = _offlineOperations();
    }
  });

  final dispose = graph.where((event) {
    // filter the right events
    return [DataGraphEventType.addEdge, DataGraphEventType.removeEdge]
            .contains(event.type) &&
        event.keys.length == 2 &&
        event.keys.containsFirst(_offlineAdapterKey);
  }).addListener((_) {
    if (notifier.mounted) {
      // recalculate all pending offline operations
      notifier.state = _offlineOperations();
    }
  });

  notifier.onDispose = dispose;

  return notifier;
});
