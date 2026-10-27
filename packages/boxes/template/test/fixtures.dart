// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'package:noted_box_template/noted_box_template.dart';

/// Box data with keys this version doesn't know, in an odd style.
const String futureData =
    '{ "text":"Buy milk", "color":"green", "pin":{"x":[ 1, 2.50 ]}, "z":true }';

/// The node of a page file holding one sticky label.
String labelNode({
  String data = futureData,
  String snapshot = 'Buy milk',
  int version = 1,
}) =>
    '{"id":"b1","type":"text","x":10,"y":20,"width":260,"height":120,'
    '"text":"$snapshot","noted":{"type":"${StickyLabelCodec.id}","v":$version,'
    '"rev":"r1","data":$data}}';

/// A page file with one sticky label.
String pageSource({
  String data = futureData,
  String snapshot = 'Buy milk',
  int version = 1,
}) =>
    '{"nodes":[${labelNode(data: data, snapshot: snapshot, version: version)}],'
    '"noted":{"format":1,"pageId":"p1","parentId":null,"title":"T","order":0}}';
