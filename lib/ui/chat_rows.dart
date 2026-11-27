/// A chat's rows: the list a chat is drawn in, bottom up, kept able to go straight to any one of them (Matt,
/// 2026-11-26, of the chat map: "when clicking something far up it doesn't go all the way to the message because it's
/// still loading i assume and it's overall still kind of glitchy ... do a revamp to make it far more performant and
/// smooth").
///
/// A plain list knows where a row is only by having laid out every row before it. Sent far, it builds and lays out
/// every row on the way (a hundred messages off, a hundred bubbles made to be thrown away, in one frame), and a row it
/// has not built it cannot be sent to at all: the map guessed, looked again a frame later, and guessed again. And once
/// there, a picture loading in a row under the one gone to pushed it off the screen.
///
/// This list keeps how tall each row is ([RowHeights]: measured where a row has been laid out, the mean of those
/// measured where it has not) and reads every place from that:
///
///  * moved to where none of the rows it has built are wanted, it lets them go and begins again at the row its heights
///    put there, building only what is near;
///  * told to [RenderChatRows.hold] a row, it puts that row where it was asked to be in the same frame, exactly, and
///    keeps it there while the rows round it change their heights, until the list is moved by anything else;
///  * as rows are laid out and turn out taller or shorter than they were taken to be, it corrects the scroll offset
///    under them, in the same layout, so nothing on the screen moves and an offset of 0 is still the newest row.
///
/// Everything else is the list it is made from: the same rows, built as they come near, the same controller, the same
/// offsets wherever every row between has been measured.
library;

import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show ChangeNotifier, Listenable, precisionErrorTolerance;
import 'package:flutter/rendering.dart';
import 'package:flutter/scheduler.dart' show SchedulerBinding;
import 'package:flutter/widgets.dart';

/// How tall each of a list's rows is: as measured where the row has been laid out, and taken as the mean of those
/// measured where it has not. Asked where a row starts (the heights before it, summed) and which row is at an offset,
/// both in a handful of steps however long the chat: the sums are kept as a Fenwick tree.
class RowHeights {
  RowHeights({double guess = 64})
      : _guess = guess,
        _given = guess;

  /// What a row is taken to be while none has been measured.
  double _guess;

  /// What the rows never measured were last given, all at once ([regive]).
  double _given;
  int _n = 0;
  Float64List _tall = Float64List(0);
  Uint8List _known = Uint8List(0);

  /// [_sums] at j (from 1) is the sum of the `j & -j` rows ending with row j - 1.
  Float64List _sums = Float64List(1);
  int _measured = 0;
  double _measuredSum = 0;
  bool _fresh = true;

  /// How wide the list was when these were measured: at another width each row wraps afresh, and they are forgotten
  /// ([forget]). Kept here and not by the list, since a chat's heights outlast its list ([named]).
  double? across;

  /// The list's first few rows (its newest messages), by whatever it tells rows apart by ([ChatListView.idOf]): one
  /// of them found further up the list than it was means rows came in under it ([insert]).
  List<Object?> first = const [];

  /// How many of its first rows are kept in [first].
  static const int told = 8;

  /// How many lists on the page hold these now, and whether they were forgotten while one did ([forgetChat]).
  int _holders = 0;
  bool _dropped = false;
  String? _name;

  /// A list on the page takes these as its own, or lets go of them.
  void taken() => _holders++;
  void let() {
    if (_holders > 0) _holders--;
    final name = _name;
    if (_holders == 0 && _dropped && name != null && identical(_kept[name], this)) _kept.remove(name);
  }

  /// How many rows.
  int get length => _n;

  /// No row has ever been measured: nothing here says where anything is.
  bool get fresh => _fresh;

  /// What a row not yet laid out is taken to be: the mean of those measured.
  double get guess => _measured == 0 ? _guess : _measuredSum / _measured;

  /// [by] more rows before row [at] (new messages: at the start, or over one still going up), each taken to be
  /// [guess]: every height kept from there on is that many rows further up, with its own row still.
  void insert(int at, int by) {
    if (by <= 0 || at < 0 || at > _n) return;
    final had = _tall.length, room = had + by;
    final tall = Float64List(room), known = Uint8List(room);
    tall.setRange(0, at, _tall);
    known.setRange(0, at, _known);
    tall.fillRange(at, at + by, guess);
    // Those past the end too: what rows measured before the list was made shorter ([resize]).
    tall.setRange(at + by, room, _tall, at);
    known.setRange(at + by, room, _known, at);
    _tall = tall;
    _known = known;
    _n += by;
    _sum();
  }

  /// [by] more rows at the start.
  void unshift(int by) => insert(0, by);

  /// The tree made again from the heights, each entry handed on to the one that holds it.
  void _sum() {
    _sums = Float64List(_tall.length + 1);
    for (var j = 1; j <= _n; j++) {
      _sums[j] += _tall[j - 1];
      final over = j + (j & -j);
      if (over <= _n) _sums[over] += _sums[j];
    }
  }

  /// A row never measured is taken to be the mean of those that have been, which moves as more are: once it is a
  /// tenth away from what such rows were last given, they are all given it. (A chat's first rows are measured after
  /// every row has been given the first guess, which may be far out; and where every row is as tall as the next, a
  /// row never built is then exactly where it will be.) Whether any height changed.
  bool regive() {
    if (_measured == 0) return false;
    final g = guess;
    if ((g - _given).abs() <= _given * 0.1) return false;
    _given = g;
    var any = false;
    for (var i = 0; i < _n; i++) {
      if (_known[i] == 1 || _tall[i] == g) continue;
      _tall[i] = g;
      any = true;
    }
    if (any) _sum();
    return any;
  }

  /// Now [n] rows. More are added at the end (older messages read in), each taken to be [guess]; fewer lose the end.
  /// Rows that came in at the start are told first, by [insert]; where they are not (a list that names no rows),
  /// every height is that many rows out until its row is laid out again, which moves nothing on the screen, since
  /// places are only ever read from here.
  ///
  /// What the rows past a shorter end measured is not thrown away: a chat opened again holding fewer messages than
  /// it did, and then given the rest (a network's older pages), has them back as tall as they were, and the place it
  /// was left at is the same message still.
  void resize(int n) {
    if (n == _n) return;
    if (n < _n) {
      for (var i = n; i < _n; i++) {
        if (_known[i] == 0) continue;
        _measured--;
        _measuredSum -= _tall[i];
      }
      _n = n;
      return;
    }
    if (n > _tall.length) {
      final room = math.max(n, math.max(64, _tall.length * 2));
      _tall = Float64List(room)..setRange(0, _tall.length, _tall);
      _known = Uint8List(room)..setRange(0, _known.length, _known);
      _sums = Float64List(room + 1)..setRange(0, _n + 1, _sums);
    } else if (_sums.length < _tall.length + 1) {
      _sums = Float64List(_tall.length + 1)..setRange(0, _n + 1, _sums);
    }
    final g = guess;
    for (var i = _n; i < n; i++) {
      if (_known[i] == 1) {
        // As it measured when the list last held it.
        _measured++;
        _measuredSum += _tall[i];
      } else {
        _tall[i] = g;
      }
      // The tree's entry for this row: the rows it stands for, of which this is the last.
      final j = i + 1;
      _sums[j] = before(i) - before(j - (j & -j)) + _tall[i];
      _n = j;
    }
  }

  /// How tall row [index] is, measured or taken to be.
  double of(int index) => _tall[index];

  /// Whether row [index] has been measured since [forget].
  bool known(int index) => _known[index] == 1;

  /// Where row [index] starts: the heights of the rows before it, summed. [length] gives the whole.
  double before(int index) {
    var sum = 0.0;
    for (var j = index; j > 0; j -= j & -j) {
      sum += _sums[j];
    }
    return sum;
  }

  /// All of them.
  double get whole => before(_n);

  /// Row [index] has been laid out and is [tall].
  void set(int index, double tall) {
    _fresh = false;
    final by = tall - _tall[index];
    if (_known[index] == 0) {
      _known[index] = 1;
      _measured++;
      _measuredSum += tall;
    } else {
      _measuredSum += by;
    }
    if (by == 0) return;
    _tall[index] = tall;
    for (var j = index + 1; j <= _n; j += j & -j) {
      _sums[j] += by;
    }
  }

  /// The row at [offset]: the last that starts at or before it. The last row for an offset past the end.
  int at(double offset) {
    if (_n == 0) return 0;
    var row = 0;
    var left = offset;
    for (var step = 1 << (_n.bitLength - 1); step > 0; step >>= 1) {
      final next = row + step;
      if (next <= _n && _sums[next] <= left) {
        row = next;
        left -= _sums[next];
      }
    }
    return math.min(row, _n - 1);
  }

  /// Every height is a guess again, though still the best there is: the list is another width, or drawn in another
  /// look, and each row wraps afresh.
  void forget() {
    _guess = guess;
    _known.fillRange(0, _known.length, 0);
    _measured = 0;
    _measuredSum = 0;
  }

  /// The heights of each chat's rows, for as long as the app runs, as where each chat was left is kept
  /// (lib/ui/jump_to_latest.dart, ScrollMemory): an offset kept there is read against these when the chat is opened
  /// again, so it is the same message, and the chat opens there without laying out everything under it.
  static final Map<String, RowHeights> _kept = {};

  /// The most chats whose heights are kept.
  static const int most = 256;

  /// The heights of the rows of [chat], as ScrollMemory keys it.
  static RowHeights named(String chat) {
    final had = _kept.remove(chat);
    final heights = had ?? (RowHeights().._name = chat);
    _kept[chat] = heights;
    if (_kept.length > most) {
      // The one longest unasked for that no list on the page holds.
      final old = _kept.keys.where((k) => _kept[k]!._holders == 0).firstOrNull;
      if (old != null) _kept.remove(old);
    }
    return heights;
  }

  /// [chat]'s forgotten, with where it was left (ScrollMemory.forget): it is to be drawn in another width, look or
  /// size of words, where every height is another.
  static void forgetChat(String chat) => _forget((k) => k == chat);

  /// Every chat whose key starts with [prefix] forgotten, as ScrollMemory.forgetAll forgets where they were left.
  static void forgetAll(String prefix) => _forget((k) => k.startsWith(prefix));

  /// Every chat forgotten (for tests).
  static void clear() => _forget((_) => true);

  /// Those a list on the page still holds are left to it and forgotten when it lets go: taken from under it, the list
  /// was given new ones that knew nothing at its next build, and laid out every row from its newest up to where it
  /// stood.
  static void _forget(bool Function(String chat) which) {
    for (final chat in _kept.keys.where(which).toList()) {
      final heights = _kept[chat]!;
      if (heights._holders > 0) {
        heights._dropped = true;
      } else {
        _kept.remove(chat);
      }
    }
  }
}

/// A chat's list: [ListView.builder] with rows it can go straight to ([RenderChatRows]). Drawn bottom up by the chats
/// (`reverse: true`), so row 0 is the newest message and an offset of 0 the foot.
class ChatListView extends ListView {
  ChatListView.builder({
    super.key,
    super.reverse,
    super.controller,
    super.physics,
    super.padding,
    required super.itemBuilder,
    super.findChildIndexCallback,
    super.itemCount,
    super.keyboardDismissBehavior,
    this.chat,
    this.idOf,
  }) : super.builder();

  /// The chat, as ScrollMemory keys it: its rows' heights are kept under it between one opening and the next
  /// ([RowHeights.named]). None, and they are kept only while the list is on the page.
  final String? chat;

  /// What tells the row at [index] from every other (its message's id), asked of the first few rows when the list is
  /// given more rows: it is how new messages at the start are told from older ones read in at the end. Told, the list
  /// keeps each row's height with its row, and someone reading far back is not moved when a message comes: what is
  /// on the screen stays where it is (a plain list shows everything a row further up). Near the newest, where the new
  /// message itself is to be seen, it comes in as it always did. None, and rows are taken to come in at the end.
  final Object? Function(int index)? idOf;

  @override
  Widget buildChildLayout(BuildContext context) {
    // The padding after the last row (over the oldest message, in a list drawn bottom up): how far past its rows the
    // list scrolls.
    final insets = padding?.resolve(Directionality.maybeOf(context) ?? TextDirection.ltr) ?? EdgeInsets.zero;
    final after = switch (getAxisDirectionFromAxisReverseAndDirectionality(context, scrollDirection, reverse)) {
      AxisDirection.up => insets.top,
      AxisDirection.down => insets.bottom,
      AxisDirection.left => insets.left,
      AxisDirection.right => insets.right,
    };
    final chat = this.chat;
    return SliverChatRows(delegate: childrenDelegate, heights: chat == null ? null : RowHeights.named(chat), after: after, idOf: idOf);
  }
}

/// The sliver of a [ChatListView].
class SliverChatRows extends SliverList {
  const SliverChatRows({super.key, required super.delegate, this.heights, this.after = 0, this.idOf});

  /// The rows' heights, where they are kept past this list; its own otherwise.
  final RowHeights? heights;

  /// What the scroll view has after this list's last row (padding), which the list cannot see for itself.
  final double after;

  /// See [ChatListView.idOf].
  final Object? Function(int index)? idOf;

  @override
  SliverMultiBoxAdaptorElement createElement() => _ChatRowsElement(this);

  @override
  RenderChatRows createRenderObject(BuildContext context) => RenderChatRows(childManager: context as SliverMultiBoxAdaptorElement, heights: heights, after: after)..idOf = idOf;

  @override
  void updateRenderObject(BuildContext context, RenderChatRows renderObject) {
    renderObject
      ..kept = heights
      ..after = after
      ..idOf = idOf
      ..rows = delegate.estimatedChildCount;
  }
}

/// Says how long the list is from its heights, not from the rows that happen to be built.
class _ChatRowsElement extends SliverMultiBoxAdaptorElement {
  _ChatRowsElement(SliverChatRows super.widget) : super(replaceMovedChildren: true);

  @override
  double estimateMaxScrollOffset(SliverConstraints? constraints, {int? firstIndex, int? lastIndex, double? leadingScrollOffset, double? trailingScrollOffset}) {
    final rows = renderObject;
    if (rows is! RenderChatRows || lastIndex == null || trailingScrollOffset == null || estimatedChildCount == null) {
      return super.estimateMaxScrollOffset(constraints, firstIndex: firstIndex, lastIndex: lastIndex, leadingScrollOffset: leadingScrollOffset, trailingScrollOffset: trailingScrollOffset);
    }
    final h = rows.heights;
    final next = math.min(lastIndex + 1, h.length);
    return trailingScrollOffset + math.max(0.0, h.whole - h.before(next));
  }
}

/// A row held where it was put: row [index], the point [within] it (0 its foot, 1 its top) at [align] of the screen (0
/// the foot, 1 the top), [shift] further up.
typedef RowHold = ({int index, double within, double align, double shift});

/// Lays a chat's rows out as [RenderSliverList] does, from the first row it has, but reads where rows are from
/// [heights], so it need not have laid out everything before a row to be at it. See the library's comment.
class RenderChatRows extends RenderSliverList {
  RenderChatRows({required super.childManager, RowHeights? heights, double after = 0})
      : _heights = heights ?? RowHeights(),
        _own = heights == null,
        _after = after {
    _heights.taken();
  }

  /// The list of [position], if it is one of these: looked for under the scroll view, where the chat's list is.
  static RenderChatRows? under(ScrollPosition position) {
    RenderChatRows? found;
    void look(RenderObject o) {
      if (found != null) return;
      if (o is RenderChatRows) {
        found = o;
        return;
      }
      o.visitChildren(look);
    }

    position.context.storageContext.findRenderObject()?.visitChildren(look);
    return found;
  }

  /// How tall the rows are, and so where each is.
  RowHeights get heights => _heights;
  RowHeights _heights;
  bool _own;

  /// The heights kept past this list (another chat's, when a page is given another chat), or none for its own.
  set kept(RowHeights? value) {
    if (value == null ? _own : identical(value, _heights)) return;
    _heights.let();
    _heights = (value ?? RowHeights())..taken();
    _own = value == null;
    // Other rows altogether: none of those built is where these heights say, and nothing is held.
    _held = null;
    _afresh = true;
    markNeedsLayout();
  }

  /// How many rows the list is now given: more or fewer than it was laid out with (older messages read in, far from
  /// where the list stands) and it is laid out again, to take them into its length at once. A plain list finds out
  /// only when it is next scrolled.
  set rows(int? value) {
    if (value != null && value != _heights.length && _laidOut) markNeedsLayout();
  }

  /// See [ChatListView.idOf]: asked at layout, of the first few rows, when there are more rows than there were.
  Object? Function(int index)? idOf;

  /// What comes after the last row in the scroll view.
  double get after => _after;
  double _after;
  set after(double value) {
    if (value == _after) return;
    _after = value;
    if (_held != null) markNeedsLayout();
  }

  /// Its rows are another chat's now: those built are let go at the next layout.
  bool _afresh = false;

  /// What comes before the first row in the scroll view (padding), and how tall the screen is, as last laid out.
  double _before = 0;
  double _screen = 0;
  bool _laidOut = false;

  /// How far the list is scrolled, from its first row's foot: under 0 while the padding before it shows.
  double get scrolled => _scrolled;
  double _scrolled = 0;

  RowHold? _held;

  /// The row is held only until this layout stands: the row that was first of those built when rows came in far under
  /// it, put back where it stood so nothing on the screen moves ([_arrived]). Not a hold anyone asked for.
  bool _once = false;

  /// A row held is taken to be near what is built, and walked to from there, within this many rows ([_ahead]).
  static const int _near = 40;

  /// The list's own layout is running: the rows it lets go of are rows it has just laid out.
  bool _laying = false;

  /// Where the scroll stood when the held row was last put in its place: anywhere else at the next layout and
  /// something else has moved the list, and the row is let go.
  double _heldAt = 0;

  /// The corrections asked for in a row without a layout finishing. The viewport lays out again after each, ten times
  /// at most; past [_mostPasses] the rest waits for the next frame.
  int _passes = 0;
  static const _mostPasses = 6;

  /// Which rows are on the screen: from how far up the list (2.5 is half way up the third row) to how far. Pulled past
  /// an end, as a phone's list can be, the list is still at that end here. Null until it has been laid out with a row
  /// on the screen.
  ({double lo, double hi})? get view => _view;
  ({double lo, double hi})? _view;

  /// The first and last rows built now, or -1.
  int get first => _first;
  int get last => _last;
  int _first = -1, _last = -1;

  /// Told when [view] has changed, DURING layout: a listener may only mark something to be painted (a painter's
  /// `repaint`), never build.
  Listenable get laid => _told;
  final _Told _told = _Told();

  /// The row held, if one is.
  RowHold? get held => _once ? null : _held;

  /// Where the scroll would stand with row [index] held so (see [RowHold]), as [scrolled] is counted; exact for a
  /// row that is laid out, by the heights for one that is not.
  double placeOf(int index, {double within = 0.5, double align = 0.5, double shift = 0}) {
    final n = _heights.length;
    if (n == 0) return -_before;
    final row = index.clamp(0, n - 1);
    final want = _heights.before(row) + within * _heights.of(row) - align * _screen + shift;
    return math.max(-_before, math.min(want, _heights.whole + _after - _screen));
  }

  /// Brings row [index] to where [within], [align] and [shift] say ([RowHold]) and keeps it there: in the next frame,
  /// exactly, whether or not the row has ever been built, and through whatever the rows round it then do (a picture
  /// under it loading, older messages read in over it). It is let go when the list is next moved by anything else: a
  /// finger, a wheel, the arrow back to the newest.
  ///
  /// Asked again for the same row with another [shift] each frame, it runs the list in to the row.
  void hold(ScrollPosition position, int index, {double within = 0.5, double align = 0.5, double shift = 0}) {
    final n = _heights.length;
    if (n == 0 || !_laidOut || !attached) return;
    final k = index.clamp(0, n - 1);
    _held = (index: k, within: within, align: align, shift: shift);
    _once = false;
    var to = placeOf(k, within: within, align: align, shift: shift) + _before;
    // No further than the scroll view knows it goes, or it would spring back: the layout takes it the rest.
    if (position.hasContentDimensions) to = to.clamp(position.minScrollExtent, position.maxScrollExtent);
    if ((position.pixels - to).abs() > 0.01) position.jumpTo(to);
    // Where the scroll stands now, to the last place of its number: the least move of it by anything else is then
    // another's. (Taken as its own within half a pixel, a finger drawing the chat slowly moved nothing: each frame's
    // little move was put back.)
    _heldAt = position.pixels - _before;
    markNeedsLayout();
  }

  /// Lets go of the row held.
  void release() {
    _held = null;
    _once = false;
  }

  /// As near as two offsets that are the same come, worked out two ways.
  static const _same = 1e-6;

  /// Whether the list has been moved by anything else since the row held was last put in its place: a wheel, a finger
  /// on the chat, another piece of code. (The list finds out for itself at its next layout, and lets the row go; this
  /// is for one who would otherwise send it back there before then.)
  bool strayed(ScrollPosition position) => held != null && (position.pixels - _before - _heldAt).abs() > _same;

  /// Rows have come in near the list's start (new messages): where the list names its rows ([idOf]), finds where and
  /// how many, by the first of its first few rows that is no longer where it was and how much further up it is now.
  /// Their heights go in there too ([RowHeights.insert]). With the rows built all over them (the person is reading
  /// back), a row held is still the same message that many rows up, and with none held what is on the screen is kept
  /// where the scroll now has it. With the rows they came in among built (the person is at the newest), a row held
  /// is let go, and they come in as in any list: the page moves up to show them.
  ///
  /// The count need not have grown: a conversation that holds its newest so many, or a space its newest 300, takes
  /// one in at the start and lets one go at the end.
  ///
  /// Says how many came in under every row built, or 0: the rows built are then that many rows further up.
  int _arrived(int count, double at) {
    final idOf = this.idOf;
    if (idOf == null) return 0;
    final h = _heights;
    final was = h.first;
    final now = [for (var i = 0; i < count && i < RowHeights.told; i++) idOf(i)];
    h.first = now;
    if (was.isEmpty || now.isEmpty || h.length == 0) return 0;
    var from = 0;
    while (from < was.length && from < now.length && was[from] == now[from]) {
      from++;
    }
    if (from >= was.length || from >= now.length) return 0;
    final moved = was[from];
    if (moved == null) return 0;
    var by = 0;
    for (var i = from + 1; i < count && i <= from + 64; i++) {
      if (idOf(i) == moved) {
        by = i - from;
        break;
      }
    }
    // Not found: it has gone, or is known by another id now (one going up that has gone): no rows have come in.
    if (by == 0) return 0;
    // Where the first row built stood at the last layout, and whether all of them were over where these came in. (By
    // what was laid out then, not by the rows as they are now: rows found again by their keys have been moved up
    // already, and rows made in their old places stand where they stood.)
    final over = _laidOut && _first > from && _first < h.length;
    final stood = over ? h.before(_first) : 0.0;
    h.insert(from, by);
    final held = _held;
    if (held != null && !_once) {
      _held = over && held.index >= from ? (index: held.index + by, within: held.within, align: held.align, shift: held.shift) : null;
    } else if (over) {
      // The message that was first of those built is [by] rows up now, and is held with its foot where it stood over
      // the scroll, until this layout stands. (Held, not put back once: where more came than rows are built, the row
      // is not there to be put back until the list's own layout has built up to it.)
      _held = (index: _first + by, within: 0, align: 0, shift: at - stood);
      _once = true;
      _heldAt = at;
    }
    return over ? by : 0;
  }

  @override
  void collectGarbage(int leadingGarbage, int trailingGarbage) {
    if (_laying) {
      // The rows let go of at the start have just been laid out, and may not be what they were (another message's
      // words in the row, since one came in under it): what they measure is kept, or the rows over them would be
      // taken to stand somewhere they do not.
      final count = _heights.length;
      var child = firstChild;
      for (var k = 0; k < leadingGarbage && child != null; k++, child = childAfter(child)) {
        if (!child.hasSize) continue;
        final index = indexOf(child);
        if (index < count) _heights.set(index, paintExtentOf(child));
      }
    }
    super.collectGarbage(leadingGarbage, trailingGarbage);
  }

  @override
  void dispose() {
    _heights.let();
    _told.dispose();
    super.dispose();
  }

  int? get _count {
    final m = childManager;
    return m is SliverMultiBoxAdaptorElement ? m.estimatedChildCount : null;
  }

  @override
  void performLayout() {
    final count = _count;
    if (count == null) {
      super.performLayout();
      return;
    }
    final c = constraints;
    if (_heights.across != c.crossAxisExtent) {
      if (_heights.across != null) _heights.forget();
      _heights.across = c.crossAxisExtent;
    }
    // One of these two is always nothing: the scroll past the list's start, or the padding before it still showing.
    final at = c.scrollOffset - (c.viewportMainAxisExtent - c.remainingPaintExtent);
    if (_afresh) {
      _afresh = false;
      if (firstChild != null) collectGarbage(childCount, 0);
    }
    final came = _arrived(count, at);
    _heights.resize(count);
    _oneRun(c, came);
    _before = c.precedingScrollExtent;
    _screen = c.viewportMainAxisExtent;
    final held = _held;
    if (held != null && ((at - _heldAt).abs() > _same || held.index >= count)) release();
    final ahead = _ahead(c, count, at) ?? _down(c, count, at);
    if (ahead != null) {
      _passes++;
      _heldAt = at + ahead;
      geometry = SliverGeometry(scrollOffsetCorrection: ahead);
      return;
    }
    _begin(c, count);
    // The list's own layout, and again where what was put right after it (rows moved to where the heights say, the
    // rows never measured given another height) is to be laid out for, with nothing to correct the offset by.
    for (var again = 0;; again++) {
      if (again == _mostPasses) {
        // Too often for one frame: the rest in the next.
        SchedulerBinding.instance.addPostFrameCallback((_) {
          if (attached) markNeedsLayout();
        });
        break;
      }
      _laying = true;
      try {
        super.performLayout();
      } finally {
        _laying = false;
      }
      final by = _settle(c, count, at);
      if (by == null) break;
      if (by == 0) continue;
      geometry = SliverGeometry(scrollOffsetCorrection: by);
      return;
    }
    _laidOut = true;
  }

  /// The rows built, as they were left when the list was last given its rows, made fit for the list's own layout to
  /// begin from: it begins at the first row that has a place, and lays out or makes every row from there to where the
  /// scroll is.
  ///
  /// Rows found again by their keys have been moved to where they now are and have lost their places, and a row has
  /// been made in each old place. So the rows built can be several runs with rows missing between (more came in than
  /// were built), or begin with rows that have no place (rows went from under them), or have a row standing where
  /// none was built (the row once there is kept alive off the screen, and this is the one made in its place).
  ///
  /// Told that [came] rows came in under all those built ([_arrived]), the run kept is the rows themselves, where the
  /// heights now put them: the one that was first is held where it stood, and they keep what a row holds (a picture
  /// decoded, a video playing).
  ///
  /// Not told, it is as in a plain list: each place keeps its row, which shows what is that many messages newer or
  /// older, and the page moves by it. Two things a plain list does are not done. The row made where none was built
  /// is let go: a plain list begins from it, building every row between there and the scroll, and here the place it
  /// has is no place at all (it is the kept row's, from whenever that was last laid out, and the rows have been named
  /// anew since). And rows without a place that lead up to one that has a place are given theirs under it, each as
  /// tall as it is, where a plain list lets them go and makes them again.
  void _oneRun(SliverConstraints c, int came) {
    final head = firstChild;
    if (head == null) return;
    final count = _heights.length;
    if (came > 0) {
      final runs = <({int skip, int rows, int from, int to, bool laid})>[];
      var seen = 0, skip = 0, from = -1, last = -1;
      var laid = false;
      for (RenderBox? child = head; child != null; child = childAfter(child), seen++) {
        final index = indexOf(child);
        if (from < 0) {
          from = index;
        } else if (index != last + 1) {
          runs.add((skip: skip, rows: seen - skip, from: from, to: last, laid: laid));
          skip = seen;
          from = index;
          laid = false;
        }
        laid = laid || child.hasSize;
        last = index;
      }
      runs.add((skip: skip, rows: seen - skip, from: from, to: last, laid: laid));
      if (runs.length > 1) {
        // The run the row that was first is in, or the nearest to it of those that were laid out before.
        final row = _first + came;
        int off(int k) => row < runs[k].from ? runs[k].from - row : (row > runs[k].to ? row - runs[k].to : 0);
        var keep = -1;
        for (var k = 0; k < runs.length; k++) {
          if (runs[k].laid && (keep < 0 || off(k) < off(keep))) keep = k;
        }
        if (keep >= 0) collectGarbage(runs[keep].skip, seen - runs[keep].skip - runs[keep].rows);
      }
    } else {
      bool stray(RenderBox child) => !child.hasSize && (indexOf(child) < _first || indexOf(child) > _last);
      var lead = 0, trail = 0;
      for (RenderBox? child = head; child != null && stray(child); child = childAfter(child)) {
        lead++;
      }
      if (lead < childCount) {
        for (var child = lastChild; child != null && stray(child); child = childBefore(child)) {
          trail++;
        }
      }
      if (lead > 0 || trail > 0) collectGarbage(lead, trail);
    }
    final first = firstChild;
    if (first == null || childScrollOffset(first) != null) return;
    if (came == 0) {
      RenderBox? placed = first;
      var none = 0;
      var joined = true;
      while (placed != null && childScrollOffset(placed) == null) {
        final next = childAfter(placed);
        if (next != null && indexOf(next) != indexOf(placed) + 1) joined = false;
        placed = next;
        none++;
      }
      if (placed != null) {
        if (!joined) {
          collectGarbage(none, 0);
          return;
        }
        final box = c.asBoxConstraints();
        var foot = childScrollOffset(placed)!;
        for (var child = childBefore(placed); child != null; child = childBefore(child)) {
          child.layout(box, parentUsesSize: true);
          foot -= paintExtentOf(child);
          (child.parentData! as SliverMultiBoxAdaptorParentData).layoutOffset = foot;
        }
        return;
      }
    }
    // None of them has a place (or they are where the heights were told they are): by the heights.
    final index = indexOf(first);
    if (index < count) (first.parentData! as SliverMultiBoxAdaptorParentData).layoutOffset = _heights.before(index);
  }

  /// With a row held: lays out the rows already built, before the list's own layout, to learn at once how far what is
  /// under the held row has grown or shrunk (a picture loaded, new messages came), and says what to correct the
  /// scroll offset by for the row to be where it is held. Null for nothing.
  ///
  /// The list's own layout, run first at the offset as it stood, would let go of the rows the change pushed past its
  /// far edge, and the corrected layout after it would want them back: made again, and whatever they held (a picture
  /// decoded, a video playing) lost.
  ///
  /// A held row not built, but within [_near] rows of those that are, is walked to from them, each row on the way
  /// built and measured, for the same reason: where it is is then known and not guessed, and the list's own layout is
  /// not run at a guess, letting go of rows that are wanted after all. (A chat of eight messages under two tall
  /// pictures: the eighth pressed, the pictures were on the screen before and after, and were made again.)
  double? _ahead(SliverConstraints c, int count, double at) {
    final held = _held;
    final first = firstChild;
    if (held == null || first == null || _passes >= _mostPasses) return null;
    var offset = childScrollOffset(first);
    if (offset == null) return null;
    final box = c.asBoxConstraints();
    final wanted = held.index;
    var from = indexOf(first), index = from;
    var found = false;
    for (RenderBox? child = first; child != null; child = childAfter(child), index++) {
      // A row missing between two built: the list's own layout fills it, and what is corrected is corrected after.
      if (indexOf(child) != index) return null;
      child.layout(box, parentUsesSize: true);
      (child.parentData! as SliverMultiBoxAdaptorParentData).layoutOffset = offset;
      final tall = paintExtentOf(child);
      if (index < count) _heights.set(index, tall);
      if (index == wanted) found = true;
      offset = offset! + tall;
    }
    if (from >= count || wanted >= count) return null;
    if (!found && wanted >= index && wanted - index < _near) {
      // Over the rows built: on up to it.
      for (; index <= wanted; index++) {
        final child = insertAndLayoutChild(box, after: lastChild, parentUsesSize: true);
        if (child == null) break;
        (child.parentData! as SliverMultiBoxAdaptorParentData).layoutOffset = offset;
        final tall = paintExtentOf(child);
        _heights.set(index, tall);
        offset = offset! + tall;
        found = index == wanted;
      }
    } else if (!found && wanted < from && from - wanted <= _near) {
      // Under them: down to it.
      var foot = childScrollOffset(first)!;
      while (from > wanted) {
        final child = insertAndLayoutLeadingChild(box, parentUsesSize: true);
        if (child == null) break;
        from--;
        final tall = paintExtentOf(child);
        foot -= tall;
        (child.parentData! as SliverMultiBoxAdaptorParentData).layoutOffset = foot;
        _heights.set(from, tall);
        found = from == wanted;
      }
    }
    _heights.regive();
    // A held row not built and not near is far off: the list begins again at it ([_begin]) and it is put in its place
    // after.
    if (!found) return null;
    final head = firstChild!;
    final tidy = _heights.before(indexOf(head)) - childScrollOffset(head)!;
    var by = tidy.abs() > _slack ? tidy : 0.0;
    final more = placeOf(held.index, within: held.within, align: held.align, shift: held.shift) - (at + by);
    if (more.abs() > _slack) by += more;
    if (tidy != 0) _move(tidy);
    return by == 0 ? null : by;
  }

  /// Near the list's start, with rows wanted under the first one built (the newest messages, perhaps never laid out:
  /// they came while the person read back, or the chat was sent far over them): they are laid out here, as far down
  /// as is wanted or to the newest, each as tall as it is, and the offset corrected by what that makes of where the
  /// rest stand. Null for nothing.
  ///
  /// Left to the list's own layout: where the newest is reached with room left under it (the rows were not as tall as
  /// they were taken to be), it puts the newest at 0 and the scroll at its start whatever was on the screen, and
  /// everything slipped by that much in the one frame the person came to the foot (some hundred pixels after a few
  /// messages; a plain list slips there too, by its own count).
  double? _down(SliverConstraints c, int count, double at) {
    final first = firstChild;
    if (first == null || _held != null || _passes >= _mostPasses) return null;
    final wanted = c.scrollOffset + c.cacheOrigin;
    var from = indexOf(first);
    var foot = childScrollOffset(first);
    if (from == 0 || from > _near || from >= count || foot == null) return null;
    // At its very start the list is laid out to its newest row, whatever the heights say is there.
    final all = wanted <= precisionErrorTolerance;
    if (!all && foot <= wanted) return null;
    final box = c.asBoxConstraints();
    while (from > 0 && (all || foot! > wanted)) {
      final child = insertAndLayoutLeadingChild(box, parentUsesSize: true);
      if (child == null) break;
      from--;
      final tall = paintExtentOf(child);
      foot = foot! - tall;
      (child.parentData! as SliverMultiBoxAdaptorParentData).layoutOffset = foot;
      _heights.set(from, tall);
    }
    // The first row built to where the heights now put it (the newest to 0), and the scroll with it, as far as the
    // scroll goes: with less under what is on the screen than there was room for, it is at its foot.
    final tidy = _heights.before(from) - foot!;
    if (tidy == 0) return null;
    _move(tidy);
    final by = math.max(tidy, -(at + _before));
    return by.abs() > _slack ? by : null;
  }

  /// Where none of the rows built are wanted any more (the list was sent far), lets them go and begins again at the
  /// row the heights put there. [RenderSliverList] would lay out every row on the way.
  void _begin(SliverConstraints c, int count) {
    if (count == 0) return;
    final from = c.scrollOffset + c.cacheOrigin, to = from + c.remainingCacheExtent;
    final first = firstChild;
    if (first == null) {
      // Opened where it was left: straight there where the heights were kept, and from the newest row up, as a plain
      // list, where nothing is known yet.
      if (_heights.fresh || from <= 0) return;
    } else {
      final a = childScrollOffset(first);
      if (a == null) return;
      // How far up the rows built reach: by those that have a place (rows found again by their keys and moved have
      // none yet), each as tall as it is or, just made in a row's old place, as tall as that row was.
      var z = a;
      for (RenderBox? child = first; child != null; child = childAfter(child)) {
        final o = childScrollOffset(child);
        if (o == null) continue;
        final index = indexOf(child);
        z = math.max(z, o + (child.hasSize ? paintExtentOf(child) : (index < count ? _heights.of(index) : 0.0)));
      }
      // Near enough to walk to (a couple of screens): as a plain list does, laying out the rows between, which lands
      // on the very pixel whatever those rows turn out to measure. Only further than that is the walk given up for a
      // fresh start, at the row the heights put there. With a row held there is no pixel to land on (the row is put
      // in its place whatever is between), so nothing is walked: a hold drawn fast along the map built the rows
      // between and let them go in the frame they were built.
      final far = _held != null ? 0.0 : math.max(_screen * 2, _walked);
      if (z >= from - far && a <= to + far) return;
      collectGarbage(childCount, 0);
    }
    // At the row held, where it is among what is wanted: the rows under it are then laid out down from it, as tall
    // as they are, and none is built only to be let go when it is put in its place.
    var row = _heights.at(from);
    final held = _held;
    if (held != null && held.index < count) {
      final foot = _heights.before(held.index);
      if (foot <= to && foot + _heights.of(held.index) >= from) row = held.index;
    }
    addInitialChild(index: row, layoutOffset: _heights.before(row));
  }

  /// After the list's own layout: keeps what the rows measure, puts the first row where the heights now say it is and
  /// the held row where it is held, and says what to correct the scroll offset by for nothing on the screen to have
  /// moved. Null for nothing (the layout stands), 0 to lay out again as it is.
  double? _settle(SliverConstraints c, int count, double at) {
    final own = geometry!.scrollOffsetCorrection;
    for (var child = firstChild; child != null; child = childAfter(child)) {
      if (!child.hasSize) continue;
      final index = indexOf(child);
      if (index < count) _heights.set(index, paintExtentOf(child));
    }
    final regiven = _heights.regive();
    final first = firstChild;
    final firstAt = first == null ? null : childScrollOffset(first);
    final tidy = first == null || firstAt == null || indexOf(first) >= count ? 0.0 : _heights.before(indexOf(first)) - firstAt;
    final room = _passes < _mostPasses;
    if (own != null) {
      // The list's own correction (a row came in under the first and would not fit over the newest end): ours with it.
      final by = own + (room ? tidy : 0);
      if (room && tidy != 0) _move(tidy);
      _passes++;
      _heldAt = at + by;
      return by.abs() < precisionErrorTolerance ? 0 : by;
    }
    var by = tidy.abs() > _slack ? tidy : 0.0;
    final held = _held;
    if (held != null) {
      final want = placeOf(held.index, within: held.within, align: held.align, shift: held.shift);
      final more = want - (at + by);
      if (more.abs() > _slack) by += more;
    }
    if (by != 0 && room) {
      if (tidy != 0) _move(tidy);
      _passes++;
      _heldAt = at + by;
      return by;
    }
    if (by != 0) {
      // Too many in one frame: as it is for now (rows stand where the list laid them, which is right on the screen),
      // and the rest in the next.
      SchedulerBinding.instance.addPostFrameCallback((_) {
        if (attached) markNeedsLayout();
      });
    } else if (tidy != 0) {
      _move(tidy);
      // Moved far with nothing to correct the offset by (the held row's correction and the rows' own came to nothing
      // between them: a row under the built ones turned out taller than it was taken to be): the layout is made
      // again for where the rows now stand. Left as it was, part of the screen was empty and stayed so.
      if (tidy.abs() > _slack) return 0;
    }
    // The rows never measured have been taken to be another height: the list's length, worked out before that, is
    // worked out again.
    if (by == 0 && regiven) return 0;
    if (_once && by == 0) {
      // Put back where it stood: let go.
      _held = null;
      _once = false;
    } else if (held != null && by == 0) {
      // Kept from where it was asked to be by an end of the list: held where it stands. It would go there later, by
      // itself, when the list grew (pressed at the map's top, then older messages read in over it: everything on the
      // screen moved half a screen, some hundreds of milliseconds after the press).
      final asked = _heights.before(held.index) + held.within * _heights.of(held.index) - held.align * _screen + held.shift;
      if ((asked - at).abs() > _slack && _screen > 0) _held = (index: held.index, within: held.within, align: held.align + (asked - at) / _screen, shift: held.shift);
    }
    _passes = 0;
    _heldAt = at;
    _scrolled = at;
    _look(at);
    return null;
  }

  /// Under this much nothing is corrected: a hundredth of a pixel is not seen, and sums of many heights differ by less.
  static const _slack = 0.01;

  /// The list walks at least this far to where it is sent (and two screens, if that is more) before it would rather
  /// begin again there ([_begin]).
  static const double _walked = 1200;

  /// Every row built moved [by], in the list's own offsets.
  void _move(double by) {
    for (var child = firstChild; child != null; child = childAfter(child)) {
      final d = child.parentData! as SliverMultiBoxAdaptorParentData;
      if (d.layoutOffset != null) d.layoutOffset = d.layoutOffset! + by;
    }
  }

  /// Which rows are on the screen, with the list scrolled [at], and whether that is news.
  void _look(double at) {
    final top = at + _screen;
    double? lo, hi;
    var first = -1, last = -1;
    for (var child = firstChild; child != null; child = childAfter(child)) {
      final o = childScrollOffset(child);
      if (o == null || !child.hasSize) continue;
      final index = indexOf(child), tall = paintExtentOf(child);
      if (first < 0) first = index;
      last = index;
      if (tall <= 0 || o + tall <= at || o >= top) continue;
      final a = index + ((at - o) / tall).clamp(0.0, 1.0), b = index + ((top - o) / tall).clamp(0.0, 1.0);
      if (lo == null || a < lo) lo = a;
      if (hi == null || b > hi) hi = b;
    }
    final view = lo == null ? null : (lo: lo, hi: hi!);
    if (view == _view && first == _first && last == _last) return;
    _view = view;
    _first = first;
    _last = last;
    _told.tell();
  }
}

class _Told extends ChangeNotifier {
  void tell() => notifyListeners();
}
