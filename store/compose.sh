#!/bin/zsh
# Renders the App Store screenshots (1320 x 2868, 6.9") from store/raw with store/frame.html.
# Captions live in frame.html. Run store/capture.sh first.
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
cd "${0:A:h}/.."
[[ build/snap -nt store/tools/snap.swift ]] || xcrun swiftc -O store/tools/snap.swift -o build/snap
mkdir -p store/screenshots
count=$(build/snap "file://$PWD/store/frame.html?n=1" 1320x2868@0.5 /dev/null 0.5)
for n in {1..$count}; do
  out=store/screenshots/$n.png
  build/snap "file://$PWD/store/frame.html?n=$n" 1320x2868@0.5 $out 1 >/dev/null
  # The App Store wants exactly 1320 x 2868 and no alpha channel.
  sips -s format jpeg $out --out ${out:r}.jpg >/dev/null && rm $out
  echo "$n $(sips -g pixelWidth -g pixelHeight ${out:r}.jpg | awk '/pixel/ {printf "%s ", $2}')"
done
# The iPhone Duo set (2853 x 2007, inner display), once store/capture.sh duo has run.
if [[ -d store/raw-duo ]]; then
  mkdir -p store/screenshots-duo
  for n in {1..$count}; do
    out=store/screenshots-duo/$n.png
    build/snap "file://$PWD/store/frame.html?n=$n&d=duo" 2853x2007@0.5 $out 1 >/dev/null
    # The snapshot renders at half scale, so odd sizes come out a pixel bigger: crop to exact.
    sips -c 2007 2853 $out >/dev/null
    sips -s format jpeg $out --out ${out:r}.jpg >/dev/null && rm $out
  done
  echo "duo $(sips -g pixelWidth -g pixelHeight store/screenshots-duo/1.jpg | awk '/pixel/ {printf "%s ", $2}')"
fi
# The product page header (3840 x 1646) and search result artwork (3840 x 2560).
for kind size in header 3840x1646 search 3840x2560; do
  build/snap "file://$PWD/store/art.html?k=$kind" $size@0.5 store/$kind.png 1 >/dev/null
  sips -s format jpeg -s formatOptions 90 store/$kind.png --out store/$kind.jpg >/dev/null && rm store/$kind.png
  echo "$kind $(sips -g pixelWidth -g pixelHeight store/$kind.jpg | awk '/pixel/ {printf "%s ", $2}')"
done
# The search result video (1920 x 1280) and header video (3840 x 1646): 10-second loops drawn by
# art.html's frame(t).
[[ build/film -nt store/tools/film.swift ]] || xcrun swiftc -O store/tools/film.swift -o build/film 2>/dev/null
build/film "file://$PWD/store/art.html?k=search&anim=1" 3840x2560@0.25 store/search.mp4 10 30 | sed 's/^/search.mp4 /'
build/film "file://$PWD/store/art.html?k=header&anim=1" 3840x1646@0.5 store/header.mp4 10 30 | sed 's/^/header.mp4 /'
# The website's link preview and app screens, if the site is next to this project.
SITE=~/Documents/helthtransfer
[[ -d $SITE ]] || exit 0
build/snap "file://$PWD/store/og.html" 1200x630@0.5 $SITE/og.png 1 >/dev/null && echo "og.png"
for name in home send-done receive-plan receive-done; do
  sips -s format jpeg -s formatOptions 80 --resampleWidth 640 store/raw/$name.png --out $SITE/img/$name.jpg >/dev/null
done
echo "site img"
