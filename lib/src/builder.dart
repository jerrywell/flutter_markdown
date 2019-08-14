// Copyright 2016 The Chromium Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'dart:io';

import 'package:flutter/gestures.dart';
import 'package:flutter/widgets.dart';
import 'package:markd/markdown.dart' as md;
//import 'package:path/path.dart' as p;

import 'style_sheet.dart';

final Set<String> _kBlockTags = new Set<String>.from(<String>[
  'p',
  'h1',
  'h2',
  'h3',
  'h4',
  'h5',
  'h6',
  'li',
  'blockquote',
  'pre',
  'ol',
  'ul',
  'hr',
  'table'
]);

const List<String> _kListTags = const <String>['ul', 'ol'];

bool _isBlockTag(String tag) => _kBlockTags.contains(tag);
bool _isListTag(String tag) => _kListTags.contains(tag);

class _BlockElement {
  _BlockElement(this.tag);

  final String tag;
  final List<Widget> children = <Widget>[];

  int nextListIndex = 0;
}

/// A collection of widgets that should be placed adjacent to (inline with)
/// other inline elements in the same parent block.
/// 
/// Inline elements can be textual (a/em/strong) represented by [RichText] 
/// widgets or images (img) represented by [Image.network] widgets.
/// 
/// Inline elements can be nested within other inline elements, inheriting their
/// parent's style along with the style of the block they are in.
/// 
/// When laying out inline widgets, first, any adjacent RichText widgets are 
/// merged, then, all inline widgets are enclosed in a parent [Wrap] widget.
class _InlineElement {
  _InlineElement(this.tag, {this.style});
 
  final String tag;

  /// Created by merging the style defined for this element's [tag] in the
  /// delegate's [MarkdownStyleSheet] with the style of its parent.
  final TextStyle style;

  final List<Widget> children = <Widget>[];
}

/// A delegate used by [MarkdownBuilder] to control the widgets it creates.
abstract class MarkdownBuilderDelegate {
  /// Returns a gesture recognizer to use for an `a` element with the given
  /// `href` attribute.
  GestureRecognizer createLink(String href);

  /// Returns formatted text to use to display the given contents of a `pre`
  /// element.
  ///
  /// The `styleSheet` is the value of [MarkdownBuilder.styleSheet].
  TextSpan formatText(MarkdownStyleSheet styleSheet, String code);

  /// Give a chance to do processing for text
  TextSpan textProcess(String innerTag, String outerTag, TextStyle style, String text, GestureRecognizer recognizer);

  /// Give a chance to add a wrapper of child
  Widget elementWrapper(String innerTag, String outerTag, Widget child);

  /// called to return the custom checklist item
  Widget buildChecklist(md.Element liElement);

  /// Called to return the custom image widget
  Widget buildImage(String url, double width, double height);

  /// Called to return the custom table widget
  Widget buildTable(md.Element tableElement);

  /// Give a chance to add a wrapper of style for inline tag
  TextStyle inlineStyleWrapper(String tag, TextStyle style);
}

/// Builds a [Widget] tree from parsed Markdown.
///
/// See also:
///
///  * [Markdown], which is a widget that parses and displays Markdown.
class MarkdownBuilder implements md.NodeVisitor {
  /// Creates an object that builds a [Widget] tree from parsed Markdown.
  MarkdownBuilder({ this.delegate, this.styleSheet, this.imageDirectory});

  /// A delegate that controls how link and `pre` elements behave.
  final MarkdownBuilderDelegate delegate;

  /// Defines which [TextStyle] objects to use for each type of element.
  final MarkdownStyleSheet styleSheet;

  /// The base directory holding images referenced by Img tags with local file paths.
  final Directory imageDirectory;

  final List<String> _listIndents = <String>[];
  final List<_BlockElement> _blocks = <_BlockElement>[];
  final List<_InlineElement> _inlines = <_InlineElement>[];
  final List<GestureRecognizer> _linkHandlers = <GestureRecognizer>[];

  /// Returns widgets that display the given Markdown nodes.
  ///
  /// The returned widgets are typically used as children in a [ListView].
  List<Widget> build(List<md.Node> nodes) {
    _listIndents.clear();
    _blocks.clear();
    _inlines.clear();
    _linkHandlers.clear();

    _blocks.add(new _BlockElement(null));

    for (md.Node node in nodes) {
      assert(_blocks.length == 1);
      node.accept(this);
    }

    assert(_inlines.isEmpty);
    return _blocks.single.children;
  }

  @override
  void visitText(md.Text text) {
    if (_blocks.last.tag == null) // Don't allow text directly under the root.
      return;

    _addParentInlineIfNeeded(_blocks.last.tag);

    final elements = _extractElementsForTag();
    final innerElement = elements[0];
    final outerElement = elements[1];
//    final last = innerElement ?? outerElement ?? _blocks.last;

    final TextSpan span = _blocks.last.tag == 'pre'
      ? delegate.formatText(styleSheet, text.text)
      : delegate.textProcess(innerElement?.tag, outerElement?.tag, _inlines.last.style, text.text, _linkHandlers.isNotEmpty ? _linkHandlers.last : null);
//      : new TextSpan(
//          style: _inlines.last.style,
//          text: text.text,
//          recognizer: _linkHandlers.isNotEmpty ? _linkHandlers.last : null,
//        );

    _inlines.last.children.add(new RichText(
      textScaleFactor: styleSheet.textScaleFactor,
      text: span,
    ));
  }

  @override
  bool visitElementBefore(md.Element element) {
    final String tag = element.tag;
    if (_isBlockTag(tag)) {
      _addAnonymousBlockIfNeeded(styleSheet.styles[tag]);
      if (_isListTag(tag))
        _listIndents.add(tag);
      _blocks.add(new _BlockElement(tag));
    } else {
      _addParentInlineIfNeeded(_blocks.last.tag);

      TextStyle parentStyle = _inlines.last.style;
      final style = styleSheet.styles[tag];
      final mergedStyle = delegate.inlineStyleWrapper(tag, style == null ? parentStyle : parentStyle == null ? style : parentStyle.merge(style));
      _inlines.add(new _InlineElement(
        tag,
        style: mergedStyle
        //style: parentStyle.merge(styleSheet.styles[tag]),
      ));
    }

    if (tag == 'a') {
      _linkHandlers.add(delegate.createLink(element.attributes['href']));
    }

    if (element.isEmpty) {
      visitElementAfter(element);
      return false;
    }

    return true;
  }

  /// return elements which are the most inner one and the most outer one in [_blocks]
  List<_BlockElement> _extractElementsForTag() {
    final length = _blocks.length;
    // the most outer one is empty element, _blocks[0], we skip it.
    final outerTag = length > 1 ? _blocks[1] : null;
    final innerTag = length > 2 ? _blocks[length - 1] : null;

    return <_BlockElement>[innerTag, outerTag];
  }

  @override
  void visitElementAfter(md.Element element) {
    final String tag = element.tag;
    final elements = _extractElementsForTag();
    final outerElement = elements[1];

    if (_isBlockTag(tag)) {
      _addAnonymousBlockIfNeeded(styleSheet.styles[tag]);

      final _BlockElement current = _blocks.removeLast();
      Widget child;

      if (current.children.isNotEmpty) {
        child = new Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: current.children,
        );
      } else {
        child = const SizedBox();
      }

      if (_isListTag(tag)) {
        assert(_listIndents.isNotEmpty);
        _listIndents.removeLast();
      } else if (tag == 'li') {
        if (_listIndents.isNotEmpty) {
          final isChecklist = element.attributes['class'] == 'todo';
          Widget bullet;
          if (isChecklist)
            bullet = delegate.buildChecklist(element);
          else
            bullet = new SizedBox(
              width: styleSheet.listIndent,
              child: _buildBullet(_listIndents.last, element),
            );

          child = new Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              bullet,
              new Expanded(child: child)
            ],
          );
        }
      } else if (tag == 'blockquote') {
        child = new DecoratedBox(
          decoration: styleSheet.blockquoteDecoration,
          child: new Padding(
            padding: new EdgeInsets.all(styleSheet.blockquotePadding),
            child: child,
          ),
        );
      } else if (tag == 'pre') {
        child = new DecoratedBox(
          decoration: styleSheet.codeblockDecoration,
          child: new Padding(
            padding: new EdgeInsets.all(styleSheet.codeblockPadding),
            child: child,
          ),
        );
      } else if (tag == 'hr') {
        child = new DecoratedBox(
          decoration: styleSheet.horizontalRuleDecoration,
          child: child,
        );
      } else if (tag == 'table') {
        child = delegate.buildTable(element);
        assert(child != null);
      }

      _addBlockChild(delegate.elementWrapper(tag, outerElement.tag, child));
    } else {
      final _InlineElement current = _inlines.removeLast();
      final _InlineElement parent = _inlines.last;

      if (tag == 'img') {
        // create an image widget for this image
        current.children.add(_buildImage(element.attributes['src']));
      } else if (tag == 'a') {
        _linkHandlers.removeLast();
      }

      if (current.children.isNotEmpty) {
        parent.children.addAll(current.children);
      }
    }
  }

  Widget _buildImage(String src) {
    final List<String> parts = src.split('#');
    if (parts.isEmpty)
      return const SizedBox();

    // final String path = parts.first;
    double width;
    double height;
    if (parts.length == 2) {
      final List<String> dimensions = parts.last.split('x');
      if (dimensions.length == 2) {
        width = double.parse(dimensions[0]);
        height = double.parse(dimensions[1]);
      }
    }

    Widget child = delegate.buildImage(src, width, height);
    // Quire: Don't use this section, we assume all comming src is http url.
    // Uri uri = Uri.parse(path);
    // Widget child;
    // if (uri.scheme == 'http' || uri.scheme == 'https') {
    //   child = new Image.network(uri.toString(), width: width, height: height);
    // } else if (uri.scheme == 'data') {
    //   child = _handleDataSchemeUri(uri, width, height);
    // } else if (uri.scheme == "resource") {
    //   child = new Image.asset(path.substring(9), width: width, height: height);
    // } else {
    //   String filePath = (imageDirectory == null
    //       ? uri.toFilePath()
    //       : p.join(imageDirectory.path, uri.toFilePath()));
    //   child = new Image.file(new File(filePath), width: width, height: height);
    // }

    if (_linkHandlers.isNotEmpty) {
      TapGestureRecognizer recognizer = _linkHandlers.last;
      return new GestureDetector(child: child, onTap: recognizer.onTap);
    } else {
      return child;
    }
  }

//  Widget _handleDataSchemeUri(Uri uri, final double width, final double height) {
//    final String mimeType = uri.data.mimeType;
//    if (mimeType.startsWith('image/')) {
//      return new Image.memory(uri.data.contentAsBytes(), width: width, height: height);
//    } else if (mimeType.startsWith('text/')) {
//      return new Text(uri.data.contentAsString());
//    }
//    return const SizedBox();
//  }

  Widget _buildBullet(String listTag, md.Element element) {
    if (listTag == 'ul')
      return new Text('•', textAlign: TextAlign.center, style: styleSheet.styles['li']);

    final int index = _blocks.last.nextListIndex;
    return new Padding(
      padding: const EdgeInsets.only(right: 5.0),
      child: new Text('${index + 1}.', textAlign: TextAlign.right, style: styleSheet.styles['li']),
    );
  }

  void _addParentInlineIfNeeded(String tag) {
    if (_inlines.isEmpty) {
      _inlines.add(new _InlineElement(
        tag,
        style: styleSheet.styles[tag],
      ));
    }
  }

  void _addBlockChild(Widget child) {
    final _BlockElement parent = _blocks.last;
    if (parent.children.isNotEmpty)
      parent.children.add(new SizedBox(height: styleSheet.blockSpacing));
    parent.children.add(child);
    parent.nextListIndex += 1;
  }

  void _addAnonymousBlockIfNeeded(TextStyle style) {
    if (_inlines.isEmpty) {
      return;
    }

    final _InlineElement inline = _inlines.single;
    if (inline.children.isNotEmpty) {
      List<Widget> mergedInlines = _mergeInlineChildren(inline);
      final Wrap wrap = new Wrap(children: mergedInlines);
      _addBlockChild(wrap);
      _inlines.clear();
    }
  }

  /// Merges adjacent [TextSpan] children of the given [_InlineElement]
  List<Widget> _mergeInlineChildren(_InlineElement inline) {
    List<Widget> mergedTexts = <Widget>[];
    for (Widget child in inline.children) {
      if (mergedTexts.isNotEmpty && mergedTexts.last is RichText && child is RichText) {
        RichText previous = mergedTexts.removeLast();
        TextSpan previousTextSpan = previous.text;
        List<TextSpan> children = previousTextSpan.children != null
            ? new List.from(previousTextSpan.children)
            : [previousTextSpan];
        children.add(child.text);
        TextSpan mergedSpan = new TextSpan(children: children);
        mergedTexts.add(new RichText(
          textScaleFactor: styleSheet.textScaleFactor,
          text: mergedSpan,
        ));
      } else {
        mergedTexts.add(child);
      }
    }
    return mergedTexts;
  }
}
