#!/usr/bin/env bash
# setting the locale, some users have issues with different locales, this forces the correct one
export LC_ALL=pt_BR.UTF-8

fahrenheit=$1
isFixedLocation=$2
location=$3

# echo "fahrenheit = $fahrenheit"
# if $fahrenheit; then
#   echo "fahrenheit is true"
# else
#   echo "fahrenheit is false"
# fi

# echo "isFixedLocation = $isFixedLocation"
# echo "location = $location"

# display_location() {
#   if $isFixedLocation && [ "$location" ]; then
#     echo " $location"
#   elif $isFixedLocation; then
#     city=$(curl -s https://ipinfo.io/city 2>/dev/null)
#     region=$(curl -s https://ipinfo.io/region 2>/dev/null)
#     echo " $city, $region"
#   else
#     echo ''
#   fi
# }

# fetch_weather_information() {
# display_weather=$1
# %m moon phase
# %p precipitation for 3h
# %C weather
# %t temperature
# + or %20: space
# curl -sL wttr.in/$location\?format="%C+%t$display_weather"

# &m is for meters format
# curl wttr.in/"$location"\?format="%m+%p+%C+%t"\&lang=pt-br\&m

# }

#get weather display
# display_weather() {
#   if $fahrenheit; then
#     display_weather='&u' # for USA system
#   else
#     display_weather='&m' # for metric system
#   fi
#   weather_information=$(fetch_weather_information $display_weather)

#   # weather_condition=$(echo $weather_information | rev | cut -d ' ' -f2- | rev) # Sunny, Snow, etc
#   temperature=$(echo $weather_information | rev | cut -d ' ' -f 1 | rev)       # +31°C, -3°F, etc
#   # unicode=$(forecast_unicode $weather_condition)

#   # echo "$unicode${temperature/+/}" # remove the plus sign to the temperature
#   echo "${temperature/+/}" # remove the plus sign to the temperature
# }

# forecast_unicode() {
#   # weather_condition=$(echo $weather_condition | awk '{print tolower($0)}')

#   # echo "$weather_condition "
#   # if [[ $weather_condition =~ 'snow' ]]; then
#   #   echo '❄ '
#   # elif [[ (($weather_condition =~ 'rain') || ($weather_condition =~ 'shower')) ]]; then
#   #   echo '☂ Chuva '
#   # elif [[ (($weather_condition =~ 'overcast') || ($weather_condition =~ 'cloud')) ]]; then
#   #   echo '☁ Nublado '
#   # elif [[ (($weather_condition =~ 'Sunny') || ($weather_condition =~ 'cloud')) ]]; then
#   #   echo '☀️ Sol '
#   # elif [[ $weather_condition = 'NA' ]]; then
#   #   echo ''
#   # else
#   #   echo ''
#   # fi
# }

# main() {
# echo "$(display_weather)$(display_location)"
# %m moon phase
# %p precipitation for 3h
# %C weather
# %t temperature
# + or %20: space
# echo $LC_ALL
# echo $LANG
curl wttr.in/"$location"\?format="%m+|+%D+-+%d+|+%p+|+%C+%t+%l"\&lang=pt-br\&m
# }

#run main driver program
# main
