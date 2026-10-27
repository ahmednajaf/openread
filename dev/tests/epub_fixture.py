"""Small EPUB 3 fixture with multiple chapters in one spine document."""
import io
import sys
import zipfile


def chapter_book():
    files = {
        'mimetype': 'application/epub+zip',
        'META-INF/container.xml': '<container><rootfile full-path="OPS/book.opf"/></container>',
        'OPS/book.opf': '''<package xmlns="http://www.idpf.org/2007/opf" xmlns:dc="http://purl.org/dc/elements/1.1/" version="3.0">
          <metadata><dc:title>A Chaptered Book</dc:title><dc:creator>Fixture Author</dc:creator></metadata>
          <manifest><item id="main" href="Text/main.xhtml"/><item id="end" href="Text/end.xhtml"/>
          <item id="nav" href="nav.xhtml" properties="nav"/><item id="extra" href="extra.xhtml"/></manifest>
          <spine><itemref idref="nav"/><itemref idref="main"/><itemref idref="extra" linear="no"/><itemref idref="end"/></spine>
        </package>''',
        # Deliberately write the last document before the first.
        'OPS/Text/end.xhtml': '<html><body><h1>End heading</h1><p>The final chapter ends here.</p></body></html>',
        'OPS/Text/main.xhtml': '''<html><head><title>Do not speak the metadata</title></head><body>
          <h1 id="start">Opening heading</h1><p>🙂 The first chapter starts here.</p>
          <h2 id="part two">Second heading</h2><p>The second chapter starts here.</p>
        </body></html>''',
        'OPS/nav.xhtml': '''<html xmlns:epub="http://www.idpf.org/2007/ops"><body>
          <nav epub:type="landmarks"><a href="Text/main.xhtml">Ignore landmarks</a></nav>
          <nav epub:type="toc"><ol><li><a href="Text/main.xhtml#start">First &amp; foremost</a></li>
          <li><a href="Text/main.xhtml#part%20two"><span>Second chapter</span></a></li>
          <li><a href="Text/end.xhtml">Final chapter</a></li></ol></nav></body></html>''',
        'OPS/extra.xhtml': '<p>Ignore this supplementary document.</p>',
    }
    output = io.BytesIO()
    with zipfile.ZipFile(output, 'w') as book:
        for name, content in files.items():
            book.writestr(name, content)
    return output.getvalue()


if __name__ == '__main__':
    sys.stdout.buffer.write(chapter_book())
