class LocationPrivacy {
  const LocationPrivacy._();

  static double shareCoordinate(double value, {required bool precise}) =>
      precise ? value : (value * 100).roundToDouble() / 100;
}
