wro4j:

1.9.0

dependency-report:

<plugin>
    <groupId>org.apache.maven.plugins</groupId>
    <artifactId>maven-project-info-reports-plugin</artifactId>
    <version>2.2</version>
</plugin>

release:

quarkus-petclinic pom.xml

<version>1.0.0.RELEASE</version>

<quarkus.package.type>uber-jar</quarkus.package.type>

<plugin>
   <artifactId>maven-deploy-plugin</artifactId>
   <version>2.8.1</version>
   <executions>
      <execution>
         <id>default-deploy</id>
         <phase>deploy</phase>
         <goals>
            <goal>deploy</goal>
         </goals>
      </execution>
   </executions>
</plugin>
