FROM ruby:2.6.6
RUN mkdir /myapp
WORKDIR /myapp
COPY Gemfile /myapp/Gemfile
COPY Gemfile.lock /myapp/Gemfile.lock
RUN bundle install
COPY . /myapp
RUN chmod +x /myapp/wait-for-it.sh
EXPOSE 3000