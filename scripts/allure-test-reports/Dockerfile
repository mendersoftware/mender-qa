FROM java:latest

RUN wget https://dl.bintray.com/qameta/maven/io/qameta/allure/allure-commandline/2.13.1/allure-commandline-2.13.1.zip && \
    unzip allure-commandline-2.13.1.zip && \
    rm allure-commandline-2.13.1.zip

RUN ln -s /allure-2.13.1/bin/allure /usr/bin/allure

COPY entrypoint.sh /

ENTRYPOINT "/entrypoint.sh"
