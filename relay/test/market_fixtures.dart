import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

/// What the Marketplace's tests share (market_pack_test.dart, market_test.dart): the docs' two example packs, and PNGs
/// made to order.
///
/// The packs are the app's test/fixtures/packs/bills.ghostplugin and parcels.ghostplugin, byte for byte (two-space
/// indent, a final newline), copied here so the relay's tests stand on their own until those files are on the branch;
/// market_pack_test.dart holds the two to each other once they are.

/// examples/plugins/bills.ghostplugin: canonical bytes 2,193, SHA-256 5c07c72f…62e7.
const String billsPack = r'''{
  "format": "ghost-plugin/1",
  "id": "bills",
  "version": "1.0.0",
  "name": "Bills",
  "tagline": "Bills and payment reminders in a tab of their own",
  "description": "Texts from companies about a bill (a statement that's ready, an amount due) go to a Bills tab, with the amount large on the row and a press to copy it. Receipts for payments you've made are a kind in the list's filter, which can mark them read as they come. Nobody in your contacts is ever sorted.",
  "icon": "iVBORw0KGgoAAAANSUhEUgAAAEAAAABACAYAAACqaXHeAAAAaklEQVR42u3awQ0AIAgAMfZfGoeQEMHeAMb0AT6MkCRJkq7K5gAAAPA2wLTzAQAAAAAAAAD1F6x68AAAAMAQBAAAAABbAAAAAIYgAAAAAGzbAgAAADAEAQAAAADAFgC/xAAA+AtAkiRJwzpcxpX3TIHg+gAAAABJRU5ErkJggg==",
  "symbol": "calculator",
  "hue": "amber",
  "shelf": "organise",
  "labels": [
    "bills",
    "money",
    "sorting"
  ],
  "permissions": [
    "sort",
    "copy",
    "markread"
  ],
  "developer": "yourname",
  "support": "https://example.com/plugins/bills",
  "settings": [
    {
      "type": "toggle",
      "key": "autoread",
      "label": "Mark receipts as read",
      "hint": "As they come: texts that say a payment went through.",
      "default": false,
      "icon": "check-check"
    },
    {
      "type": "words",
      "key": "extra",
      "label": "More words for bills",
      "hint": "A text with any of these goes to Bills too.",
      "placeholder": "council tax, water rates"
    }
  ],
  "rules": {
    "tags": [
      {
        "tag": "bill",
        "any": [
          "your bill is ready",
          "your statement is ready",
          "amount due {amount}",
          "amount due: {amount}",
          "payment of {amount} is due",
          "minimum payment due"
        ],
        "wordsFrom": "extra",
        "detail": {
          "from": "token"
        }
      },
      {
        "tag": "paid",
        "any": [
          "payment received",
          "thank you for your payment",
          "payment of {amount} received",
          "we've received your payment"
        ],
        "detail": {
          "from": "token"
        }
      }
    ],
    "sections": [
      {
        "key": "bills",
        "label": "Bills",
        "icon": "calculator",
        "kind": "tab",
        "takes": {
          "tagged": [
            "bill"
          ],
          "untagged": [
            "paid"
          ]
        },
        "row": {
          "value": "{tag:bill}",
          "caption": "A bill",
          "end": "copyamount"
        }
      },
      {
        "key": "receipts",
        "label": "Receipts",
        "icon": "check-check",
        "kind": "filter",
        "takes": {
          "tagged": [
            "paid"
          ]
        }
      }
    ],
    "actions": [
      {
        "id": "copyamount",
        "label": "Copy the amount",
        "icon": "copy",
        "slots": [
          "row",
          "list.conversation.menu",
          "conversation.message.menu"
        ],
        "when": {
          "tagged": [
            "bill"
          ]
        },
        "do": "copy",
        "text": "{tag:bill}",
        "say": "Amount copied"
      }
    ],
    "incoming": [
      {
        "in": "receipts",
        "do": [
          "markread"
        ],
        "setting": "autoread"
      }
    ]
  }
}
''';

/// examples/plugins/parcels.ghostplugin: canonical bytes 2,943, SHA-256 81ca3c8f…70a2.
const String parcelsPack = r'''{
  "format": "ghost-plugin/1",
  "id": "parcels",
  "version": "1.0.0",
  "name": "Parcels",
  "tagline": "Delivery texts in one tab, tracking numbers a press away",
  "description": "Texts about a parcel (shipped, out for delivery, delivered, a missed delivery) go to a Parcels tab. Where a text gives a tracking number, the row shows it and a press copies it. It can silence parcel texts, and answer a courier for you with a line you send yourself. Nobody in your contacts is ever sorted.",
  "icon": "iVBORw0KGgoAAAANSUhEUgAAAEAAAABACAYAAACqaXHeAAAAV0lEQVR42u3YsQ0AAARFQfsvzQg6kZ+7ARSvEFEFAAAAsOjnBBBAgNsAKXMEEEAAAQQQwB0ggAACWIICCCCAAAIIIIAAAggggAACCOAfIIAAAgAAABBmAFislQaarP23AAAAAElFTkSuQmCC",
  "symbol": "map-pin",
  "hue": "indigo",
  "shelf": "organise",
  "labels": [
    "deliveries",
    "sorting"
  ],
  "permissions": [
    "sort",
    "copy",
    "write",
    "move",
    "mute",
    "links"
  ],
  "links": [
    "https://example.com/plugins/parcels/help"
  ],
  "developer": "yourname",
  "support": "https://example.com/plugins/parcels",
  "settings": [
    {
      "type": "choice",
      "key": "level",
      "label": "What counts as a parcel",
      "options": [
        {
          "value": "strict",
          "label": "Only clear delivery texts"
        },
        {
          "value": "loose",
          "label": "Anything about shipping",
          "hint": "Catches more, and now and then a text that isn't about a parcel."
        }
      ],
      "default": "strict"
    },
    {
      "type": "toggle",
      "key": "quiet",
      "label": "Silence parcel texts",
      "hint": "No sound or banner for texts in Parcels. They still arrive.",
      "default": false,
      "icon": "bell"
    }
  ],
  "rules": {
    "tags": [
      {
        "tag": "parcel",
        "any": [
          "your {words:0-3} has shipped",
          "your {words:0-3} is out for delivery",
          "out for delivery",
          "has been delivered",
          "missed delivery",
          "delivery attempt"
        ]
      },
      {
        "tag": "parcel",
        "any": [
          "shipped",
          "dispatched",
          "on its way"
        ],
        "when": {
          "setting": {
            "key": "level",
            "is": "loose"
          }
        }
      },
      {
        "tag": "track",
        "any": [
          "tracking number {code:8-24}",
          "tracking number: {code:8-24}",
          "tracking no. {code:8-24}"
        ],
        "when": {
          "tagged": [
            "parcel"
          ]
        },
        "detail": {
          "from": "token"
        }
      }
    ],
    "sections": [
      {
        "key": "parcels",
        "label": "Parcels",
        "icon": "map-pin",
        "kind": "tab",
        "takes": {
          "tagged": [
            "parcel"
          ]
        },
        "row": {
          "value": "{tag:track}",
          "caption": "A parcel",
          "face": {
            "name": "Parcels",
            "color": "#4F46E5"
          },
          "end": "copytrack"
        }
      }
    ],
    "actions": [
      {
        "id": "copytrack",
        "label": "Copy the tracking number",
        "icon": "copy",
        "slots": [
          "row",
          "list.conversation.menu",
          "conversation.header"
        ],
        "when": {
          "tagged": [
            "track"
          ]
        },
        "do": "copy",
        "text": "{tag:track}",
        "say": "Tracking number copied"
      },
      {
        "id": "neighbour",
        "label": "Ask for it to go to a neighbour",
        "icon": "pen-line",
        "slots": [
          "conversation.message.menu"
        ],
        "when": {
          "tagged": [
            "parcel"
          ]
        },
        "do": "write",
        "text": "If I'm out, please leave it with a neighbour. Thank you!"
      },
      {
        "id": "help",
        "label": "Where's my parcel?",
        "icon": "external-link",
        "slots": [
          "list.conversation.menu"
        ],
        "when": {
          "tagged": [
            "parcel"
          ]
        },
        "do": "link",
        "url": "https://example.com/plugins/parcels/help"
      },
      {
        "id": "notparcel",
        "label": "Not a parcel",
        "icon": "undo-2",
        "slots": [
          "list.conversation.menu"
        ],
        "when": {
          "section": "parcels"
        },
        "do": "move",
        "to": "main"
      }
    ],
    "incoming": [
      {
        "in": "parcels",
        "do": [
          "mute"
        ],
        "setting": "quiet"
      }
    ]
  }
}
''';

const examplePacks = {'bills': billsPack, 'parcels': parcelsPack};

/// The app's own copies, where the branch has them (../test/fixtures/packs, run from relay/).
Map<String, Uint8List> appFixtures() {
  final dir = Directory('../test/fixtures/packs');
  if (!dir.existsSync()) return const {};
  return {
    for (final f in dir.listSync().whereType<File>().where((f) => f.path.endsWith('.ghostplugin'))) f.uri.pathSegments.last.replaceAll('.ghostplugin', ''): f.readAsBytesSync(),
  };
}

/// A PNG's chunks as the relay reads them: the signature, then each [chunks] entry (type, data) with its length and
/// CRC, IHDR first (made from [width], [height]) unless [ihdr] is false, IEND last unless [iend] is false, and [after]
/// past the end. Nothing in IDAT is a real picture: the relay never decodes one.
Uint8List png(int width, int height, {List<(String, List<int>)> chunks = const [], bool ihdr = true, bool iend = true, List<int> after = const []}) {
  final out = BytesBuilder();
  out.add(const [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]);
  void chunk(String type, List<int> data) {
    final t = ascii.encode(type);
    out.add(_u32(data.length));
    out.add(t);
    out.add(data);
    out.add(_u32(_crc([...t, ...data])));
  }

  if (ihdr) chunk('IHDR', [..._u32(width), ..._u32(height), 8, 6, 0, 0, 0]);
  final rest = chunks.isEmpty ? const [('IDAT', [0x78, 0x9C, 0x63, 0x00, 0x00, 0x00, 0x01, 0x00, 0x01])] : chunks;
  for (final (type, data) in rest) {
    chunk(type, data);
  }
  if (iend) chunk('IEND', const []);
  out.add(after);
  return out.takeBytes();
}

List<int> _u32(int v) => [(v >> 24) & 0xff, (v >> 16) & 0xff, (v >> 8) & 0xff, v & 0xff];

final List<int> _crcTable = [
  for (var n = 0; n < 256; n++)
    () {
      var c = n;
      for (var k = 0; k < 8; k++) {
        c = (c & 1) != 0 ? 0xEDB88320 ^ (c >> 1) : c >> 1;
      }
      return c;
    }(),
];

int _crc(List<int> bytes) {
  var c = 0xFFFFFFFF;
  for (final b in bytes) {
    c = _crcTable[(c ^ b) & 0xff] ^ (c >> 8);
  }
  return c ^ 0xFFFFFFFF;
}
