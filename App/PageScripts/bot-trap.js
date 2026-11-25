// Shared by the scripts that read a form (included with an "include bot-trap" line): a box no person sees, set as a trap for bots ("honeypot"). The
// arrests.org request portals add two or three, with labels made of random words from the page ("Privacy Address", "Request: Authorization: of") that
// change on every load: hidden from assistive tech, out of the tab order, in a box one pixel tall. A trap is never filled, ticked, chosen or asked about.
var botTrap=function(e){
  if(!e||!e.getBoundingClientRect) return false;
  if(e.closest('[aria-hidden="true"]')) return true;
  var r=e.getBoundingClientRect(); if(r.right<=0||r.left>=window.innerWidth+1000) return true;
  if(e.getAttribute('tabindex')==='-1'){for(var p=e.parentElement,i=0;p&&i<3;p=p.parentElement,i++){if(p.getBoundingClientRect().height<=1) return true;}}
  return false;};
