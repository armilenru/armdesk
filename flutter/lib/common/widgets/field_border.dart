import 'dart:ui' show lerpDouble;

import 'package:flutter/material.dart';

/// A rounded frame whose label rises inside the field.
///
/// With [OutlineInputBorder] a floating label climbs onto the frame and cuts
/// a gap in it. A border that reports `isOutline == false` keeps the label
/// inside, where the forms on www.armilen.ru keep theirs, and the field still
/// gets the same rounded frame and fill.
class FieldBorder extends InputBorder {
  const FieldBorder({
    super.borderSide = const BorderSide(),
    this.radius = 8,
  });

  final double radius;

  @override
  bool get isOutline => false;

  @override
  FieldBorder copyWith({BorderSide? borderSide, double? radius}) => FieldBorder(
      borderSide: borderSide ?? this.borderSide, radius: radius ?? this.radius);

  @override
  EdgeInsetsGeometry get dimensions => EdgeInsets.all(borderSide.width);

  @override
  FieldBorder scale(double t) =>
      FieldBorder(borderSide: borderSide.scale(t), radius: radius * t);

  @override
  ShapeBorder? lerpFrom(ShapeBorder? a, double t) => a is FieldBorder
      ? FieldBorder(
          borderSide: BorderSide.lerp(a.borderSide, borderSide, t),
          radius: lerpDouble(a.radius, radius, t)!)
      : super.lerpFrom(a, t);

  @override
  ShapeBorder? lerpTo(ShapeBorder? b, double t) => b is FieldBorder
      ? FieldBorder(
          borderSide: BorderSide.lerp(borderSide, b.borderSide, t),
          radius: lerpDouble(radius, b.radius, t)!)
      : super.lerpTo(b, t);

  RRect _shape(Rect rect) =>
      RRect.fromRectAndRadius(rect, Radius.circular(radius));

  @override
  Path getInnerPath(Rect rect, {TextDirection? textDirection}) =>
      Path()..addRRect(_shape(rect).deflate(borderSide.width));

  @override
  Path getOuterPath(Rect rect, {TextDirection? textDirection}) =>
      Path()..addRRect(_shape(rect));

  @override
  void paint(Canvas canvas, Rect rect,
      {double? gapStart,
      double gapExtent = 0.0,
      double gapPercentage = 0.0,
      TextDirection? textDirection}) {
    if (borderSide.style == BorderStyle.none) return;
    canvas.drawRRect(
        _shape(rect).deflate(borderSide.width / 2), borderSide.toPaint());
  }

  @override
  bool operator ==(Object other) =>
      other is FieldBorder &&
      other.borderSide == borderSide &&
      other.radius == radius;

  @override
  int get hashCode => Object.hash(borderSide, radius);
}
