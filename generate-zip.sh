#!/bin/sh
set -x

VERSION=$(grep \<version\> install.xml  | perl -n -e '/>(.*)</; print $1;')

cd ..
mv squeezebox-22tracks 22tracks
zip -r squeezebox-22tracks-$VERSION.zip 22tracks -x \*.zip \*.sh \*.git\* \*README\* \*webauth\*
mv 22tracks squeezebox-22tracks
SHA=$(shasum squeezebox-22tracks-$VERSION.zip | awk '{print $1;}')

cat <<EOF > public.xml
<extensions>
	<details>
		<title lang="EN">22tracks Plugin</title>
	</details>
	<plugins>
		<plugin name="22tracks" version="$VERSION" minTarget="7.5" maxTarget="*">
			<title lang="EN">22tracks</title>
			<desc lang="EN">Play music from 22tracks.com</desc>
			<url>http://danielvijge.github.io/squeezebox-22tracks/squeezebox-22tracks-$VERSION.zip</url>
			<link>https://github.com/danielvijge/squeezebox-22tracks</link>
			<sha>$SHA</sha>
			<creator>Daniel Vijge</creator>
		</plugin>
	</plugins>
</extensions>
EOF
