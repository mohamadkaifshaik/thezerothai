import 'dart:collection';
import 'dart:typed_data';

import 'package:drift/backends.dart';
import 'package:logging/logging.dart';

final _log = Logger('storage.session_memory');

/// A drift executor that keeps the cache's rows in Dart memory for as long as
/// the app runs, with no sqlite behind it. Pure Dart, so it needs neither
/// sqlite3 (native) nor `sqlite3.wasm` (web).
///
/// Start-up's last resort (see `openCacheDatabase`): when neither the on-disk
/// nor the in-memory sqlite database can be used, the app runs on this one, so
/// a feed, the notifications and the messages show what the server returned.
/// Nothing outlives the page or process. Memory is bounded by the same
/// retention rules as the normal cache, since the same stores run on it
/// (`kTimelineRetention`, `kMessagesPerConversation`, the notification prune),
/// and an account switch empties it the same way (`AppDatabase.claimCacheFor`
/// and `clearAll` delete every account row).
///
/// It understands the subset of SQL drift generates for this app's tables:
/// `CREATE TABLE`, `SELECT` (`*` or `COUNT`) with `WHERE`, `ORDER BY` and
/// `LIMIT`, `INSERT` with `ON CONFLICT ... DO UPDATE`, `UPDATE`, `DELETE`, and
/// transactions with savepoints (rolled back from snapshots). `WHERE` takes
/// `AND`, `OR`, `NOT`, comparisons, `LIKE`, `IN` and `IS [NOT] NULL`. A
/// statement outside that subset throws in debug builds (so tests catch it)
/// and, in release, reads as no rows and changes nothing.
QueryExecutor sessionMemoryExecutor() => DelegatedDatabase(_SessionMemory());

class _SessionMemory extends DatabaseDelegate {
  final _Engine _engine = _Engine();
  final _MemoryVersion _version = _MemoryVersion();
  bool _open = false;

  // A version kept in memory: 0 on the first open, so drift runs `onCreate`
  // and the tables are created.
  @override
  DbVersionDelegate get versionDelegate => _version;

  @override
  TransactionDelegate get transactionDelegate => const NoTransactionDelegate();

  @override
  bool get isOpen => _open;

  @override
  Future<void> open(QueryExecutorUser db) async {
    _open = true;
  }

  @override
  Future<void> close() async {
    _open = false;
    _engine.clear();
    _version.reset();
  }

  @override
  Future<QueryResult> runSelect(String statement, List<Object?> args) async {
    final result = _guarded(statement, args);
    return QueryResult(result?.columns ?? const [], result?.rows ?? const []);
  }

  @override
  Future<int> runInsert(String statement, List<Object?> args) async =>
      _guarded(statement, args)?.lastInsertId ?? 0;

  @override
  Future<int> runUpdate(String statement, List<Object?> args) async =>
      _guarded(statement, args)?.changes ?? 0;

  @override
  Future<void> runCustom(String statement, List<Object?> args) async {
    _guarded(statement, args);
  }

  @override
  Future<void> runBatched(BatchedStatements statements) async {
    for (final application in statements.arguments) {
      _guarded(
        statements.statements[application.statementIndex],
        application.arguments,
      );
    }
  }

  _Result? _guarded(String statement, List<Object?> args) {
    try {
      return _engine.execute(statement, args);
    } on _Unsupported catch (error) {
      var debug = false;
      assert(debug = true);
      if (debug) {
        throw UnsupportedError('session memory cache: $error in: $statement');
      }
      // The statement text holds no row values (they are bound arguments).
      _log.warning('unsupported statement, ignored: $error');
      return null;
    }
  }
}

class _MemoryVersion extends DynamicVersionDelegate {
  int _version = 0;

  void reset() => _version = 0;

  @override
  Future<int> get schemaVersion async => _version;

  @override
  Future<void> setSchemaVersion(int version) async {
    _version = version;
  }
}

/// A statement or expression this engine does not understand.
class _Unsupported implements Exception {
  _Unsupported(this.what);

  final String what;

  @override
  String toString() => 'unsupported $what';
}

class _Result {
  _Result({
    this.columns = const [],
    this.rows = const [],
    this.changes = 0,
    this.lastInsertId = 0,
  });

  final List<String> columns;
  final List<List<Object?>> rows;
  final int changes;
  final int lastInsertId;
}

// --- storage ---------------------------------------------------------------

class _Table {
  _Table(this.name, this.columns, this.defaults, this.notNull, this.key);

  final String name;
  final List<String> columns;
  final List<Object?> defaults;
  final List<bool> notNull;

  /// Column indexes of the primary key; empty = keyed by an implicit rowid.
  final List<int> key;

  /// Rows by primary key, in insertion order. A row list is never changed in
  /// place (an update stores a new list), so a snapshot can share them.
  LinkedHashMap<Object, List<Object?>> rows = LinkedHashMap();

  int column(String name) {
    final index = columns.indexOf(name);
    if (index < 0) throw StateError('no such column: $name in ${this.name}');
    return index;
  }

  Object keyOf(List<Object?> row, int rowId) {
    if (key.isEmpty) return rowId;
    return key.map((i) => _keyPart(row[i])).join('\u0001');
  }
}

String _keyPart(Object? value) => switch (value) {
  null => 'n',
  final int v => 'i$v',
  final double v => 'd$v',
  final String v => 's$v',
  final Uint8List v => 'b${v.join(',')}',
  _ => 'o$value',
};

class _Savepoint {
  _Savepoint(this.name, this.tables);

  final String? name;
  final Map<String, LinkedHashMap<Object, List<Object?>>> tables;
}

class _Engine {
  final Map<String, _Table> _tables = {};
  final List<_Savepoint> _savepoints = [];
  int _rowId = 0;

  void clear() {
    _tables.clear();
    _savepoints.clear();
  }

  _Result execute(String sql, List<Object?> args) {
    final parser = _Parser(_tokenize(sql), args.map(_bind).toList());
    final result = parser.statement(this);
    parser.end();
    return result;
  }

  _Table table(String name) {
    final table = _tables[name];
    if (table == null) throw StateError('no such table: $name');
    return table;
  }

  // Transactions: a snapshot of every table's rows per open level.

  void begin(String? name) {
    _savepoints.add(
      _Savepoint(name, {
        for (final t in _tables.values) t.name: LinkedHashMap.of(t.rows),
      }),
    );
  }

  void commit() => _savepoints.clear();

  /// Drops the savepoint [name] (null = the whole transaction) and every one
  /// opened after it; with [restore] its snapshot is put back first.
  void release(String? name, {required bool restore}) {
    final index = name == null
        ? 0
        : _savepoints.lastIndexWhere((s) => s.name == name);
    if (index < 0 || index >= _savepoints.length) {
      if (name == null) return; // no transaction open: nothing to undo
      throw StateError('no such savepoint: $name');
    }
    if (restore) {
      final snapshot = _savepoints[index].tables;
      for (final t in _tables.values) {
        t.rows = LinkedHashMap.of(snapshot[t.name] ?? const {});
      }
    }
    _savepoints.removeRange(index, _savepoints.length);
  }

  int nextRowId() => ++_rowId;
}

// --- tokens ----------------------------------------------------------------

enum _Kind { word, quoted, string, number, param, punct }

class _Token {
  const _Token(this.kind, this.text, [this.value]);

  final _Kind kind;
  final String text;
  final Object? value;

  /// A bare word equal to [keyword] (case-insensitive). Quoted identifiers
  /// are never keywords.
  bool isWord(String keyword) =>
      kind == _Kind.word && text.toUpperCase() == keyword;

  bool isPunct(String p) => kind == _Kind.punct && text == p;

  @override
  String toString() => text;
}

const _twoCharPuncts = {'<=', '>=', '<>', '!=', '==', '||'};

List<_Token> _tokenize(String sql) {
  final tokens = <_Token>[];
  var i = 0;
  bool isWordStart(int c) =>
      (c >= 0x41 && c <= 0x5a) || (c >= 0x61 && c <= 0x7a) || c == 0x5f;
  bool isDigit(int c) => c >= 0x30 && c <= 0x39;
  while (i < sql.length) {
    final c = sql.codeUnitAt(i);
    if (c == 0x20 || c == 0x0a || c == 0x0d || c == 0x09) {
      i++;
    } else if (sql.startsWith('--', i)) {
      final eol = sql.indexOf('\n', i);
      i = eol < 0 ? sql.length : eol + 1;
    } else if (c == 0x22 || c == 0x60) {
      // "identifier" or `identifier`, a doubled quote escapes it.
      final quote = sql[i];
      final buffer = StringBuffer();
      i++;
      while (true) {
        if (i >= sql.length) throw _Unsupported('unterminated identifier');
        if (sql[i] == quote) {
          if (i + 1 < sql.length && sql[i + 1] == quote) {
            buffer.write(quote);
            i += 2;
            continue;
          }
          i++;
          break;
        }
        buffer.write(sql[i]);
        i++;
      }
      tokens.add(_Token(_Kind.quoted, buffer.toString().toLowerCase()));
    } else if (c == 0x27) {
      final buffer = StringBuffer();
      i++;
      while (true) {
        if (i >= sql.length) throw _Unsupported('unterminated string');
        if (sql[i] == "'") {
          if (i + 1 < sql.length && sql[i + 1] == "'") {
            buffer.write("'");
            i += 2;
            continue;
          }
          i++;
          break;
        }
        buffer.write(sql[i]);
        i++;
      }
      final text = buffer.toString();
      tokens.add(_Token(_Kind.string, text, text));
    } else if (isDigit(c)) {
      final start = i;
      while (i < sql.length && isDigit(sql.codeUnitAt(i))) {
        i++;
      }
      var isDouble = false;
      if (i < sql.length && sql[i] == '.') {
        isDouble = true;
        i++;
        while (i < sql.length && isDigit(sql.codeUnitAt(i))) {
          i++;
        }
      }
      final text = sql.substring(start, i);
      tokens.add(
        _Token(
          _Kind.number,
          text,
          isDouble ? double.parse(text) : int.parse(text),
        ),
      );
    } else if (c == 0x3f) {
      // ? or ?NNN
      final start = ++i;
      while (i < sql.length && isDigit(sql.codeUnitAt(i))) {
        i++;
      }
      final digits = sql.substring(start, i);
      tokens.add(
        _Token(
          _Kind.param,
          '?$digits',
          digits.isEmpty ? null : int.parse(digits),
        ),
      );
    } else if (isWordStart(c)) {
      final start = i;
      while (i < sql.length) {
        final d = sql.codeUnitAt(i);
        if (!(isWordStart(d) || isDigit(d) || d == 0x24)) break;
        i++;
      }
      tokens.add(_Token(_Kind.word, sql.substring(start, i)));
    } else {
      final two = i + 1 < sql.length ? sql.substring(i, i + 2) : '';
      if (_twoCharPuncts.contains(two)) {
        tokens.add(_Token(_Kind.punct, two));
        i += 2;
      } else if ('(),.;*=<>+-'.contains(sql[i])) {
        tokens.add(_Token(_Kind.punct, sql[i]));
        i++;
      } else {
        throw _Unsupported('character ${sql[i]}');
      }
    }
  }
  return tokens;
}

/// A drift argument as it is stored: booleans as 0/1 (as sqlite does),
/// byte lists as [Uint8List].
Object? _bind(Object? value) => switch (value) {
  final bool b => b ? 1 : 0,
  final BigInt b when b.isValidInt => b.toInt(),
  final Uint8List bytes => bytes,
  final List<int> bytes => Uint8List.fromList(bytes),
  _ => value,
};

// --- values ----------------------------------------------------------------

/// sqlite's order of storage classes: NULL, numbers, text, blobs.
int _rank(Object? v) => switch (v) {
  null => 0,
  num() => 1,
  String() => 2,
  _ => 3,
};

int _compare(Object? a, Object? b) {
  final ra = _rank(a), rb = _rank(b);
  if (ra != rb) return ra.compareTo(rb);
  return switch ((a, b)) {
    (null, null) => 0,
    (final num x, final num y) => x.compareTo(y),
    (final String x, final String y) => x.compareTo(y),
    (final Uint8List x, final Uint8List y) => _compareBytes(x, y),
    _ => throw _Unsupported('comparison of ${a.runtimeType}'),
  };
}

int _compareBytes(Uint8List a, Uint8List b) {
  final n = a.length < b.length ? a.length : b.length;
  for (var i = 0; i < n; i++) {
    if (a[i] != b[i]) return a[i].compareTo(b[i]);
  }
  return a.length.compareTo(b.length);
}

/// SQL truth of [v]: true, false or null (unknown).
bool? _truth(Object? v) => switch (v) {
  null => null,
  final bool b => b,
  final num n => n != 0,
  final String s => (num.tryParse(s) ?? 0) != 0,
  _ => false,
};

class _Row {
  _Row(this.values, [this.excluded]);

  final List<Object?> values;

  /// The proposed row of an `INSERT ... ON CONFLICT DO UPDATE` (`excluded.x`).
  final List<Object?>? excluded;
}

typedef _Eval = Object? Function(_Row row);

// --- parser / executor -----------------------------------------------------

class _Parser {
  _Parser(this._tokens, this._args);

  final List<_Token> _tokens;
  final List<Object?> _args;
  int _pos = 0;
  int _nextParam = 0;

  /// The table expressions are resolved against.
  _Table? _table;

  bool get _atEnd => _pos >= _tokens.length;

  _Token? get _peek => _atEnd ? null : _tokens[_pos];

  _Token _next() {
    if (_atEnd) throw _Unsupported('end of statement');
    return _tokens[_pos++];
  }

  bool _word(String keyword) {
    if (_peek?.isWord(keyword) ?? false) {
      _pos++;
      return true;
    }
    return false;
  }

  bool _punct(String p) {
    if (_peek?.isPunct(p) ?? false) {
      _pos++;
      return true;
    }
    return false;
  }

  void _expectWord(String keyword) {
    if (!_word(keyword)) throw _Unsupported('token ${_peek ?? 'end'}');
  }

  void _expectPunct(String p) {
    if (!_punct(p)) throw _Unsupported('token ${_peek ?? 'end'}, wanted $p');
  }

  String _name() {
    final t = _next();
    if (t.kind == _Kind.quoted) return t.text;
    if (t.kind == _Kind.word) return t.text.toLowerCase();
    throw _Unsupported('token $t, wanted a name');
  }

  /// The bare word after the next token is [keyword].
  bool _secondIs(String keyword) =>
      _pos + 1 < _tokens.length && _tokens[_pos + 1].isWord(keyword);

  void end() {
    _punct(';');
    if (!_atEnd) throw _Unsupported('trailing ${_peek!.text}');
  }

  Object? _param(_Token t) {
    final index = t.value is int ? (t.value! as int) - 1 : _nextParam++;
    if (t.value is int) _nextParam = index + 1;
    if (index < 0 || index >= _args.length) {
      throw StateError('missing argument ${index + 1}');
    }
    return _args[index];
  }

  _Result statement(_Engine engine) {
    final first = _peek;
    if (first == null) return _Result();
    if (_word('SELECT')) return _select(engine);
    if (_word('INSERT')) return _insert(engine, replace: false);
    if (_word('REPLACE')) return _insert(engine, replace: true);
    if (_word('UPDATE')) return _update(engine);
    if (_word('DELETE')) return _delete(engine);
    if (_word('CREATE')) return _create(engine);
    if (_word('DROP')) return _drop(engine);
    if (_word('BEGIN')) {
      _word('DEFERRED') || _word('IMMEDIATE') || _word('EXCLUSIVE');
      _word('TRANSACTION');
      engine.begin(null);
      return _Result();
    }
    if (_word('COMMIT') || _word('END')) {
      _word('TRANSACTION');
      engine.commit();
      return _Result();
    }
    if (_word('ROLLBACK')) {
      _word('TRANSACTION');
      String? name;
      if (_word('TO')) {
        _word('SAVEPOINT');
        name = _name();
      }
      engine.release(name, restore: true);
      return _Result();
    }
    if (_word('SAVEPOINT')) {
      engine.begin(_name());
      return _Result();
    }
    if (_word('RELEASE')) {
      _word('SAVEPOINT');
      engine.release(_name(), restore: false);
      return _Result();
    }
    throw _Unsupported('statement ${first.text}');
  }

  // SELECT cols FROM t [WHERE e] [ORDER BY ...] [LIMIT n [OFFSET m]]
  _Result _select(_Engine engine) {
    // The result columns come before FROM: find the table first.
    final start = _pos;
    var depth = 0;
    while (true) {
      final t = _next();
      if (t.isPunct('(')) depth++;
      if (t.isPunct(')')) depth--;
      if (depth == 0 && t.isWord('FROM')) break;
    }
    final table = _table = engine.table(_name());
    _skipAlias();
    final whereStart = _pos;
    _pos = start;

    final columns = <String>[];
    final evals = <_Eval>[];
    final counts = <_Eval?>[]; // non-null entry = COUNT(expr), null = row value
    var isAggregate = false;
    var star = false;
    if (_punct('*')) {
      star = true;
      columns.addAll(table.columns);
    } else {
      do {
        if (_peek?.isWord('COUNT') ?? false) {
          _pos++;
          _expectPunct('(');
          _Eval? counted;
          if (!_punct('*')) counted = _expr();
          _expectPunct(')');
          isAggregate = true;
          counts.add(counted ?? (_) => 1);
          evals.add((_) => null);
          columns.add(_alias() ?? 'count');
        } else {
          final nameToken = _peek;
          evals.add(_expr());
          counts.add(null);
          columns.add(_alias() ?? nameToken?.text ?? '');
        }
      } while (_punct(','));
    }
    _expectWord('FROM');
    _pos = whereStart;

    final where = _word('WHERE') ? _expr() : null;
    final order = <(_Eval, bool)>[];
    if (_word('ORDER')) {
      _expectWord('BY');
      do {
        final e = _expr();
        final descending = _word('DESC');
        if (!descending) _word('ASC');
        order.add((e, descending));
      } while (_punct(','));
    }
    int? limit;
    var offset = 0;
    if (_word('LIMIT')) {
      limit = _int(_expr()(_Row(const [])));
      if (_word('OFFSET')) offset = _int(_expr()(_Row(const [])));
    }

    var rows = [
      for (final values in table.rows.values)
        if (where == null || _truth(where(_Row(values))) == true) values,
    ];
    if (isAggregate) {
      if (counts.any((c) => c == null)) throw _Unsupported('mixed aggregate');
      return _Result(
        columns: columns,
        rows: [
          [
            for (final counted in counts)
              rows.where((r) => counted!(_Row(r)) != null).length,
          ],
        ],
      );
    }
    if (order.isNotEmpty) {
      rows = _sorted(rows, order);
    }
    if (offset > 0) rows = rows.skip(offset).toList();
    if (limit != null && limit >= 0) rows = rows.take(limit).toList();
    return _Result(
      columns: columns,
      rows: [
        for (final r in rows)
          star ? List.of(r) : [for (final e in evals) e(_Row(r))],
      ],
    );
  }

  List<List<Object?>> _sorted(
    List<List<Object?>> rows,
    List<(_Eval, bool)> order,
  ) {
    // Stable: ties keep insertion order.
    final indexed = [for (var i = 0; i < rows.length; i++) (i, rows[i])];
    indexed.sort((a, b) {
      for (final (eval, descending) in order) {
        final c = _compare(eval(_Row(a.$2)), eval(_Row(b.$2)));
        if (c != 0) return descending ? -c : c;
      }
      return a.$1.compareTo(b.$1);
    });
    return [for (final (_, r) in indexed) r];
  }

  int _int(Object? v) => switch (v) {
    final int n => n,
    _ => throw _Unsupported('LIMIT $v'),
  };

  String? _alias() {
    if (_word('AS')) return _name();
    return null;
  }

  /// Skips an optional `AS alias` after a table name.
  void _skipAlias() {
    if (_word('AS')) _name();
  }

  // INSERT [OR mode] INTO t (cols) VALUES (...)[, (...)]
  //   [ON CONFLICT[(cols)] DO NOTHING | DO UPDATE SET c = e, ... [WHERE e]]
  _Result _insert(_Engine engine, {required bool replace}) {
    var mode = replace ? 'REPLACE' : 'ABORT';
    if (_word('OR')) mode = _next().text.toUpperCase();
    _expectWord('INTO');
    final table = _table = engine.table(_name());
    _skipAlias();
    final targets = <int>[];
    if (_punct('(')) {
      do {
        targets.add(table.column(_name()));
      } while (_punct(','));
      _expectPunct(')');
    } else {
      targets.addAll(List.generate(table.columns.length, (i) => i));
    }
    _expectWord('VALUES');
    final valueRows = <List<Object?>>[];
    do {
      _expectPunct('(');
      final values = <Object?>[];
      do {
        values.add(_expr()(_Row(const [])));
      } while (_punct(','));
      _expectPunct(')');
      if (values.length != targets.length) {
        throw StateError(
          '${values.length} values for ${targets.length} columns',
        );
      }
      valueRows.add(values);
    } while (_punct(','));

    var onConflict = 'ABORT';
    final sets = <(int, _Eval)>[];
    _Eval? upsertWhere;
    if (_word('ON')) {
      _expectWord('CONFLICT');
      if (_punct('(')) {
        do {
          _name();
        } while (_punct(','));
        _expectPunct(')');
      }
      _expectWord('DO');
      if (_word('NOTHING')) {
        onConflict = 'IGNORE';
      } else {
        _expectWord('UPDATE');
        onConflict = 'UPDATE';
        _expectWord('SET');
        sets.addAll(_assignments(table));
        if (_word('WHERE')) upsertWhere = _expr();
      }
    }
    if (_peek?.isWord('RETURNING') ?? false) throw _Unsupported('RETURNING');
    if (mode != 'ABORT') onConflict = mode;

    var changes = 0;
    var lastId = 0;
    for (final values in valueRows) {
      final row = List<Object?>.of(table.defaults);
      for (var i = 0; i < targets.length; i++) {
        row[targets[i]] = values[i];
      }
      _checkNotNull(table, row);
      final rowId = engine.nextRowId();
      final key = table.keyOf(row, rowId);
      final existing = table.rows[key];
      if (existing == null) {
        table.rows[key] = row;
        changes++;
        lastId = rowId;
        continue;
      }
      switch (onConflict) {
        case 'IGNORE':
          continue;
        case 'REPLACE':
          table.rows[key] = row;
          changes++;
          lastId = rowId;
        case 'UPDATE':
          final context = _Row(existing, row);
          if (upsertWhere != null && _truth(upsertWhere(context)) != true) {
            continue;
          }
          final updated = List<Object?>.of(existing);
          for (final (column, eval) in sets) {
            updated[column] = eval(context);
          }
          _store(table, key, updated, rowId);
          changes++;
          lastId = rowId;
        default:
          throw StateError('UNIQUE constraint failed: ${table.name}');
      }
    }
    return _Result(changes: changes, lastInsertId: lastId);
  }

  List<(int, _Eval)> _assignments(_Table table) {
    final sets = <(int, _Eval)>[];
    do {
      final column = table.column(_name());
      _expectPunct('=');
      sets.add((column, _expr()));
    } while (_punct(','));
    return sets;
  }

  void _checkNotNull(_Table table, List<Object?> row) {
    for (var i = 0; i < row.length; i++) {
      if (row[i] == null && table.notNull[i]) {
        throw StateError(
          'NOT NULL constraint failed: ${table.name}.${table.columns[i]}',
        );
      }
    }
  }

  /// Puts [row] back after an update; a changed key moves the row.
  void _store(_Table table, Object oldKey, List<Object?> row, int rowId) {
    _checkNotNull(table, row);
    final key = table.key.isEmpty ? oldKey : table.keyOf(row, rowId);
    if (key == oldKey) {
      table.rows[key] = row;
      return;
    }
    if (table.rows.containsKey(key)) {
      throw StateError('UNIQUE constraint failed: ${table.name}');
    }
    table.rows.remove(oldKey);
    table.rows[key] = row;
  }

  // UPDATE t SET c = e, ... [WHERE e]
  _Result _update(_Engine engine) {
    if (_word('OR')) throw _Unsupported('UPDATE OR');
    final table = _table = engine.table(_name());
    _expectWord('SET');
    final sets = _assignments(table);
    final where = _word('WHERE') ? _expr() : null;
    final matched = [
      for (final entry in table.rows.entries)
        if (where == null || _truth(where(_Row(entry.value))) == true) entry,
    ];
    for (final entry in matched) {
      final context = _Row(entry.value);
      final updated = List<Object?>.of(entry.value);
      for (final (column, eval) in sets) {
        updated[column] = eval(context);
      }
      _store(table, entry.key, updated, 0);
    }
    return _Result(changes: matched.length);
  }

  // DELETE FROM t [WHERE e]
  _Result _delete(_Engine engine) {
    _expectWord('FROM');
    final table = _table = engine.table(_name());
    final where = _word('WHERE') ? _expr() : null;
    final keys = [
      for (final entry in table.rows.entries)
        if (where == null || _truth(where(_Row(entry.value))) == true)
          entry.key,
    ];
    keys.forEach(table.rows.remove);
    return _Result(changes: keys.length);
  }

  // CREATE TABLE [IF NOT EXISTS] t (column defs, table constraints)
  // CREATE [UNIQUE] INDEX ...: ignored, rows are scanned.
  _Result _create(_Engine engine) {
    _word('UNIQUE');
    if (_word('INDEX')) {
      _pos = _tokens.length;
      return _Result();
    }
    _expectWord('TABLE');
    var ifNotExists = false;
    if (_word('IF')) {
      _expectWord('NOT');
      _expectWord('EXISTS');
      ifNotExists = true;
    }
    final name = _name();
    final columns = <String>[];
    final defaults = <Object?>[];
    final notNull = <bool>[];
    final key = <String>[];
    _expectPunct('(');
    do {
      if (_peek?.isWord('PRIMARY') ?? false) {
        _pos++;
        _expectWord('KEY');
        _expectPunct('(');
        do {
          key.add(_name());
        } while (_punct(','));
        _expectPunct(')');
        continue;
      }
      if ((_peek?.isWord('UNIQUE') ?? false) ||
          (_peek?.isWord('CHECK') ?? false) ||
          (_peek?.isWord('CONSTRAINT') ?? false) ||
          (_peek?.isWord('FOREIGN') ?? false)) {
        _skipDefinition();
        continue;
      }
      columns.add(_name());
      Object? defaultValue;
      var required = false;
      while (!(_peek?.isPunct(',') ?? true) && !(_peek?.isPunct(')') ?? true)) {
        if (_word('NOT')) {
          _expectWord('NULL');
          required = true;
        } else if (_word('DEFAULT')) {
          defaultValue = _expr()(_Row(const []));
        } else if (_word('PRIMARY')) {
          _expectWord('KEY');
          key.add(columns.last);
        } else if (_punct('(')) {
          _skipParens();
        } else {
          _next(); // type names, NULL, CHECK, COLLATE x, UNIQUE, ...
        }
      }
      defaults.add(defaultValue);
      notNull.add(required);
    } while (_punct(','));
    _expectPunct(')');
    // Table options (`WITHOUT ROWID`, `STRICT`) change nothing here.
    while (!_atEnd && !(_peek?.isPunct(';') ?? false)) {
      _next();
    }
    if (engine._tables.containsKey(name)) {
      if (ifNotExists) return _Result();
      throw StateError('table $name already exists');
    }
    engine._tables[name] = _Table(name, columns, defaults, notNull, [
      for (final k in key) columns.indexOf(k),
    ]);
    return _Result();
  }

  /// Skips a table constraint up to the next top-level comma or the closing
  /// parenthesis.
  void _skipDefinition() {
    while (!(_peek?.isPunct(',') ?? true) && !(_peek?.isPunct(')') ?? true)) {
      if (_punct('(')) {
        _skipParens();
      } else {
        _next();
      }
    }
  }

  /// After an opening parenthesis: skips to its matching close.
  void _skipParens() {
    var depth = 1;
    while (depth > 0) {
      final t = _next();
      if (t.isPunct('(')) depth++;
      if (t.isPunct(')')) depth--;
    }
  }

  _Result _drop(_Engine engine) {
    if (_word('INDEX')) {
      _pos = _tokens.length;
      return _Result();
    }
    _expectWord('TABLE');
    var ifExists = false;
    if (_word('IF')) {
      _expectWord('EXISTS');
      ifExists = true;
    }
    final name = _name();
    if (engine._tables.remove(name) == null && !ifExists) {
      throw StateError('no such table: $name');
    }
    return _Result();
  }

  // --- expressions ---------------------------------------------------------

  _Eval _expr() => _or();

  _Eval _or() {
    var left = _and();
    while (_word('OR')) {
      final a = left, b = _and();
      left = (row) {
        final x = _truth(a(row)), y = _truth(b(row));
        if (x == true || y == true) return true;
        if (x == null || y == null) return null;
        return false;
      };
    }
    return left;
  }

  _Eval _and() {
    var left = _not();
    while (_word('AND')) {
      final a = left, b = _not();
      left = (row) {
        final x = _truth(a(row)), y = _truth(b(row));
        if (x == false || y == false) return false;
        if (x == null || y == null) return null;
        return true;
      };
    }
    return left;
  }

  _Eval _not() {
    if (_word('NOT')) {
      final inner = _not();
      return (row) {
        final x = _truth(inner(row));
        return x == null ? null : !x;
      };
    }
    return _comparison();
  }

  _Eval _comparison() {
    final left = _primary();
    final t = _peek;
    if (t == null) return left;
    if (t.kind == _Kind.punct) {
      final op = t.text;
      bool Function(int)? test = switch (op) {
        '=' || '==' => (c) => c == 0,
        '!=' || '<>' => (c) => c != 0,
        '<' => (c) => c < 0,
        '<=' => (c) => c <= 0,
        '>' => (c) => c > 0,
        '>=' => (c) => c >= 0,
        _ => null,
      };
      if (test == null) return left;
      _pos++;
      final right = _primary();
      return (row) {
        final a = left(row), b = right(row);
        if (a == null || b == null) return null;
        if (_rank(a) != _rank(b)) return op == '!=' || op == '<>';
        return test(_compare(a, b));
      };
    }
    if (_word('IS')) {
      final negated = _word('NOT');
      final right = _primary();
      return (row) {
        // Ranks differ => _compare is non-zero, so 0 means the same value.
        final same = _compare(left(row), right(row)) == 0;
        return negated ? !same : same;
      };
    }
    final negated =
        (_peek?.isWord('NOT') ?? false) &&
        (_secondIs('LIKE') || _secondIs('IN')) &&
        _word('NOT');
    if (_word('LIKE')) {
      final pattern = _primary();
      return (row) {
        final value = left(row), p = pattern(row);
        if (value == null || p == null) return null;
        final matches = _likeRegExp('$p').hasMatch('$value');
        return negated ? !matches : matches;
      };
    }
    if (_word('IN')) {
      _expectPunct('(');
      final items = <_Eval>[];
      if (!(_peek?.isPunct(')') ?? false)) {
        do {
          items.add(_primary());
        } while (_punct(','));
      }
      _expectPunct(')');
      return (row) {
        final value = left(row);
        if (value == null) return null;
        var sawNull = false;
        for (final item in items) {
          final v = item(row);
          if (v == null) {
            sawNull = true;
          } else if (_rank(v) == _rank(value) && _compare(v, value) == 0) {
            return !negated;
          }
        }
        return sawNull ? null : negated;
      };
    }
    return left;
  }

  _Eval _primary() {
    final t = _next();
    switch (t.kind) {
      case _Kind.param:
        final value = _param(t);
        return (_) => value;
      case _Kind.string:
      case _Kind.number:
        final value = t.value;
        return (_) => value;
      case _Kind.punct:
        if (t.text == '(') {
          final inner = _expr();
          _expectPunct(')');
          return inner;
        }
        if (t.text == '-') {
          final n = _next();
          if (n.kind != _Kind.number) throw _Unsupported('- ${n.text}');
          final value = -(n.value! as num);
          return (_) => value;
        }
        throw _Unsupported('token ${t.text}');
      case _Kind.word:
        final upper = t.text.toUpperCase();
        if (upper == 'NULL') return (_) => null;
        if (upper == 'TRUE') return (_) => 1;
        if (upper == 'FALSE') return (_) => 0;
        if (_peek?.isPunct('(') ?? false) throw _Unsupported('function $upper');
        return _columnRef(t.text.toLowerCase());
      case _Kind.quoted:
        return _columnRef(t.text);
    }
  }

  _Eval _columnRef(String first) {
    var name = first;
    var excluded = false;
    if (_punct('.')) {
      excluded = first == 'excluded';
      name = _name();
    }
    final table = _table;
    if (table == null) throw _Unsupported('column $name outside a table');
    final index = table.column(name);
    if (excluded) {
      return (row) {
        final proposed = row.excluded;
        if (proposed == null) throw _Unsupported('excluded.$name');
        return proposed[index];
      };
    }
    return (row) => row.values[index];
  }
}

/// Compiled LIKE patterns; the app uses one or two, the cap is a backstop.
final Map<String, RegExp> _likeCache = {};

/// sqlite's LIKE: `%` any run, `_` one character, ASCII case-insensitive,
/// no escape character.
RegExp _likeRegExp(String pattern) {
  if (_likeCache.length > 32) _likeCache.clear();
  return _likeCache.putIfAbsent(pattern, () {
    final buffer = StringBuffer('^');
    for (final rune in pattern.runes) {
      final c = String.fromCharCode(rune);
      buffer.write(switch (c) {
        '%' => '.*',
        '_' => '.',
        _ => RegExp.escape(c),
      });
    }
    buffer.write(r'$');
    return RegExp(buffer.toString(), caseSensitive: false, dotAll: true);
  });
}
